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
    func appKitFactories() {
        let store = RouterStore<BridgeRoute>(initialPath: [.detail])

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
}
#endif
