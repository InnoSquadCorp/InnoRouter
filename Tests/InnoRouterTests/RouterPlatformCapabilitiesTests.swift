import Testing

import InnoRouter

private enum PlatformCapabilityRoute: Route {
    case detail
}

@Suite("Router platform capabilities", .tags(.unit))
@MainActor
struct RouterPlatformCapabilitiesTests {
    @Test("Presentation styles adapt deterministically")
    func presentationStyleAdaptation() {
        let television = RouterPlatformCapabilities.declared(for: .tvOS)
        let watch = RouterPlatformCapabilities.declared(for: .watchOS)
        let catalyst = RouterPlatformCapabilities.declared(for: .macCatalyst)

        #expect(television.effectivePresentationStyle(for: .fullScreenCover) == .fullScreenCover)
        #expect(television.effectivePresentationStyle(for: .popover) == .sheet)
        #expect(watch.effectivePresentationStyle(for: .fullScreenCover) == .sheet)
        #expect(watch.effectivePresentationStyle(for: .popover) == .sheet)
        #expect(catalyst.effectivePresentationStyle(for: .fullScreenCover) == .sheet)
        #expect(catalyst.effectivePresentationStyle(for: .popover) == .popover)
    }

    @Test("Unsupported presentation options are explicit and ordered")
    func presentationOptionAdaptation() {
        let capabilities = RouterPlatformCapabilities.declared(for: .macOS)
        let presentation = RouterPresentation<PlatformCapabilityRoute>(
            route: .detail,
            style: .popover,
            options: .init(
                detents: [.medium, .large],
                selectedDetent: .medium,
                dragIndicator: .visible,
                isInteractiveDismissDisabled: true,
                compactAdaptation: .popover,
                backgroundInteraction: .enabled,
                contentInteraction: .scrolls,
                cornerRadius: 24
            )
        )

        let adaptations = capabilities.adaptations(for: presentation)

        #expect(
            adaptations.first == .presentationStyle(
                presentationID: presentation.id,
                requested: .popover,
                effective: .sheet
            )
        )
        #expect(
            adaptations.last == .presentationOptionsIgnored(
                presentationID: presentation.id,
                options: [
                    .detents,
                    .selectedDetent,
                    .dragIndicator,
                    .compactAdaptation,
                    .backgroundInteraction,
                    .contentInteraction,
                    .cornerRadius,
                ]
            )
        )
    }

    @Test("Store publishes each exact adaptation once")
    func adaptationEventDeduplication() {
        var events: [RouterEvent<PlatformCapabilityRoute>] = []
        let store = RouterStore<PlatformCapabilityRoute>(
            configuration: .init { events.append($0) }
        )
        let adaptation = RouterPlatformAdaptation.tabBadgeVisualUnavailable(
            scope: "search",
            count: 3
        )

        store.reportPlatformAdaptation(adaptation)
        store.reportPlatformAdaptation(adaptation)

        let adaptedEvents = events.compactMap { event -> RouterPlatformAdaptation? in
            guard case .platformAdapted(_, let adaptation, _) = event else { return nil }
            return adaptation
        }
        #expect(adaptedEvents == [adaptation])
    }

    @Test("Current capabilities match the compiling Apple platform")
    func currentPlatform() {
#if targetEnvironment(macCatalyst)
        #expect(RouterPlatformCapabilities.current.platform == .macCatalyst)
        #expect(RouterPlatformCapabilities.current.supports(.windowScenes))
#elseif os(iOS)
        #expect(RouterPlatformCapabilities.current.platform == .iOS)
        #expect(RouterPlatformCapabilities.current.supports(.presentationCustomization))
#elseif os(macOS)
        #expect(RouterPlatformCapabilities.current.platform == .macOS)
        #expect(RouterPlatformCapabilities.current.supports(.windowScenes))
#elseif os(tvOS)
        #expect(RouterPlatformCapabilities.current.platform == .tvOS)
        #expect(!RouterPlatformCapabilities.current.supports(.windowScenes))
#elseif os(watchOS)
        #expect(RouterPlatformCapabilities.current.platform == .watchOS)
        #expect(!RouterPlatformCapabilities.current.supports(.splitView))
#elseif os(visionOS)
        #expect(RouterPlatformCapabilities.current.platform == .visionOS)
        #expect(RouterPlatformCapabilities.current.supports(.immersiveSpace))
#endif
    }
}
