import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum PlatformRuntimeRoute: Route {
    case detail
}

@Suite("Platform runtime contract", .tags(.unit))
@MainActor
struct PlatformCapabilityRuntimeTests {
    @Test("Current target exposes its exact native capabilities")
    func currentCapabilities() {
        let capabilities = RouterPlatformCapabilities.current
        #expect(capabilities.supports(.stackNavigation))
        #expect(capabilities.supports(.tabs))

#if targetEnvironment(macCatalyst)
        #expect(capabilities.platform == .macCatalyst)
        #expect(capabilities.supports(.windowScenes))
#elseif os(iOS)
        #expect(capabilities.platform == .iOS)
        #expect(capabilities.supports(.presentationCustomization))
#elseif os(macOS)
        #expect(capabilities.platform == .macOS)
        #expect(capabilities.supports(.windowScenes))
#elseif os(tvOS)
        #expect(capabilities.platform == .tvOS)
        #expect(!capabilities.supports(.windowScenes))
#elseif os(watchOS)
        #expect(capabilities.platform == .watchOS)
        #expect(!capabilities.supports(.splitView))
#elseif os(visionOS)
        #expect(capabilities.platform == .visionOS)
        #expect(capabilities.supports(.immersiveSpace))
#endif
    }

    @Test("Presentation adaptation matches the running target")
    func presentationAdaptation() {
        let capabilities = RouterPlatformCapabilities.current

#if targetEnvironment(macCatalyst)
        #expect(capabilities.effectivePresentationStyle(for: .popover) == .popover)
        #expect(capabilities.effectivePresentationStyle(for: .fullScreenCover) == .sheet)
#elseif os(iOS)
        #expect(capabilities.effectivePresentationStyle(for: .popover) == .popover)
        #expect(
            capabilities.effectivePresentationStyle(for: .fullScreenCover)
                == .fullScreenCover
        )
#elseif os(tvOS)
        #expect(capabilities.effectivePresentationStyle(for: .popover) == .sheet)
        #expect(
            capabilities.effectivePresentationStyle(for: .fullScreenCover)
                == .fullScreenCover
        )
#else
        #expect(capabilities.effectivePresentationStyle(for: .popover) == .sheet)
        #expect(capabilities.effectivePresentationStyle(for: .fullScreenCover) == .sheet)
#endif
    }

    @Test("Platform adaptation events are emitted once per exact occurrence")
    func adaptationEvents() {
        var events: [RouterEvent<PlatformRuntimeRoute>] = []
        let store = RouterStore<PlatformRuntimeRoute>(
            configuration: .init { events.append($0) }
        )
        let adaptation = RouterPlatformAdaptation.tabBadgeVisualUnavailable(
            scope: "runtime-tab",
            count: 1
        )

        store.reportPlatformAdaptation(adaptation)
        store.reportPlatformAdaptation(adaptation)

        #expect(events.count == 1)
        guard case .platformAdapted(_, let emittedAdaptation, 0) = events[0] else {
            Issue.record("Expected one platform adaptation event at revision zero")
            return
        }
        #expect(emittedAdaptation == adaptation)
    }
}
