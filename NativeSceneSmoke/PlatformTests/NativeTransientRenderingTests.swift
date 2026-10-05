import SwiftUI
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit

private enum TransientRenderRoute: DestinationRoute {
    case root
    @MainActor static func destination(for route: Self) -> some View { Text("Root") }
}

@Suite("Mounted native transient rendering", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct NativeTransientRenderingTests {
    @Test("UIKit presents and retires each canonical transient family", arguments: [false, true])
    func nativePresentation(dialog: Bool) async throws {
        let store = try RouterStore<TransientRenderRoute>(configuration: .init(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
        )))
        let host = UIHostingController(rootView: RouterHost(store: store) { Text("Root") })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                 "This regression requires the application-hosted test target")
        let window = UIWindow(windowScene: scene)
        window.frame = .init(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let transient = RouterTransientPresentation(content: .init(title: "Native contract", actions: [
            .init(id: "ok", label: "Continue"), .init(id: "cancel", label: "Cancel", role: .cancel),
        ]))
        _ = await store.perform(dialog ? .presentConfirmationDialog(transient) : .presentAlert(transient))
        try await wait("initial presentation") { findAlert(host) != nil }
        let alert = try #require(findAlert(host))
        #expect(alert.title == "Native contract")
        #expect(alert.preferredStyle == (dialog ? .actionSheet : .alert))
        #expect(alert.actions.map(\.title) == ["Continue", "Cancel"])
        let oldHandle = try #require(store.presentationHandle())
        _ = await store.dismissPresentation(using: oldHandle)
        #expect(store.presentationHandle() == nil)
        try await wait("initial retirement") { findAlert(host) == nil }
        #expect(store.state == .rootStack)
        // A new incarnation must still render after native retirement finishes.
        _ = await store.perform(dialog ? .presentConfirmationDialog(transient) : .presentAlert(transient))
        try await wait("same-ID reentry") { findAlert(host) != nil }
        let newHandle = try #require(store.presentationHandle())
        #expect(newHandle != oldHandle)
        _ = await store.dismissPresentation(using: oldHandle)
        #expect(store.presentationHandle() == newHandle)
        _ = await store.dismissPresentation(using: newHandle)
        try await wait("final retirement") { findAlert(host) == nil }
    }

    private func findAlert(_ root: UIViewController) -> UIAlertController? {
        if let alert = root as? UIAlertController { return alert }
        if let presented = root.presentedViewController, let alert = findAlert(presented) { return alert }
        return root.children.lazy.compactMap { findAlert($0) }.first
    }

    private func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Native presentation lifecycle did not settle: \(stage)")
    }
}
#endif
