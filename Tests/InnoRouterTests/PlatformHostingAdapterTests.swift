#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing

import InnoRouter

private enum BridgeRoute: DestinationRoute {
    case detail

    @MainActor
    static func destination(for route: BridgeRoute) -> some View {
        Text(verbatim: String(describing: route))
    }
}

@Suite("Platform hosting adapters")
@MainActor
struct PlatformHostingAdapterTests {
    @Test("AppKit controller and view retain the canonical router host")
    func appKitFactories() throws {
        let store = try RouterStore<BridgeRoute>(
            initialPath: [.detail], configuration: .init(hostDescriptor: .init(
                root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
            ))
        )

        let controller = RouterAppKitBridge.hostingController(store: store) {
            Text(verbatim: "Root")
        }
        let view = RouterAppKitBridge.hostingView(store: store) {
            Text(verbatim: "Root")
        }

        #expect(controller is NSHostingController<RouterHost<BridgeRoute, Text>>)
        #expect(view is NSHostingView<RouterHost<BridgeRoute, Text>>)
        #expect(store.state.root == .stack(path: [.detail]))
    }
    @Test("AppKit bridges forward custom root and presentation declarations")
    func customAppKitDeclarations() throws {
        let presentations = RouterPresentationViewCatalog<BridgeRoute>(entries: [.stack("details")])
        let descriptor = RouterHostDescriptor<BridgeRoute>(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("bridge.custom-root"))],
            presentations: .init(entries: presentations.entries.map(\.declaration), declaration: { _ in "details" })
        )
        let store = try RouterStore<BridgeRoute>(configuration: .init(hostDescriptor: descriptor))
        let controller = RouterAppKitBridge.hostingController(
            store: store, rootDeclarationID: "bridge.custom-root", presentations: presentations
        ) { Text("Custom") }
        let view = RouterAppKitBridge.hostingView(
            store: store, rootDeclarationID: "bridge.custom-root", presentations: presentations
        ) { Text("Custom") }
        let typedController = try #require(controller as? NSHostingController<RouterHost<BridgeRoute, Text>>)
        let typedView = try #require(view as? NSHostingView<RouterHost<BridgeRoute, Text>>)
        #expect(typedController.rootView.validationFailure == nil)
        #expect(typedView.rootView.validationFailure == nil)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }
}
#endif

#if canImport(UIKit) && !os(watchOS)
import UIKit
import SwiftUI
import Testing
import InnoRouter

private enum UIKitBridgeRoute: DestinationRoute {
    case detail
    static func destination(for route: Self) -> some View { Text("Detail") }
}

@Suite("UIKit frozen hosting adapter declarations")
@MainActor
struct UIKitHostingDeclarationTests {
    @Test("UIKit bridge forwards the exact custom root and presentation catalog")
    func customDeclarations() throws {
        let presentations = RouterPresentationViewCatalog<UIKitBridgeRoute>(entries: [.stack("details")])
        let descriptor = RouterHostDescriptor<UIKitBridgeRoute>(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("bridge.custom-root"))],
            presentations: .init(entries: presentations.entries.map(\.declaration), declaration: { _ in "details" })
        )
        let store = try RouterStore<UIKitBridgeRoute>(configuration: .init(hostDescriptor: descriptor))
        let controller = RouterUIKitBridge.hostingController(
            store: store, rootDeclarationID: "bridge.custom-root", presentations: presentations
        ) { Text("Custom") }
        let typed = try #require(controller as? UIHostingController<RouterHost<UIKitBridgeRoute, Text>>)
        #expect(typed.rootView.validationFailure == nil)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }
}
#endif
