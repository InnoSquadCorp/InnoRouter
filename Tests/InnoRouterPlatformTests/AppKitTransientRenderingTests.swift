#if os(macOS)
import AppKit
import SwiftUI
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum AppKitTransientRoute: DestinationRoute {
    case root
    @MainActor static func destination(for route: Self) -> some View { Text("Root") }
}

@Suite("Mounted AppKit transient rendering", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AppKitTransientRenderingTests {
    @Test("NSAlert button responses settle the declared typed value", arguments: [false, true])
    func nativeResponse(cancel: Bool) async throws {
        let store = try RouterStore<AppKitTransientRoute>(configuration: .init(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
        )))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RouterHost(store: store) { Text("Root") })
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        let request: RouterTransientPresentationRequest<Bool> = .alert(title: "Native contract", actions: [
            .init(id: "ok", label: "Continue", value: true),
            .init(id: "cancel", label: "Cancel", role: .cancel, value: false),
        ])
        let result = Task { await store.scope().present(request) }
        defer { result.cancel() }
        try await wait { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let root = try #require(sheet.contentView)
        let button = try #require(findButton(root, title: cancel ? "Cancel" : "Continue"))
        button.performClick(nil)
        try await wait { store.presentationHandle() == nil }
        guard case .value(let value) = await result.value else {
            Issue.record("A native button must settle its declared value")
            return
        }
        #expect(value == !cancel)
        #expect(store.state == .rootStack)
        try await wait { window.attachedSheet == nil }
    }

    private func findButton(_ root: NSView, title: String) -> NSButton? {
        if let button = root as? NSButton, button.title == title { return button }
        return root.subviews.lazy.compactMap { findButton($0, title: title) }.first
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Native AppKit presentation did not settle")
    }
}
#endif
