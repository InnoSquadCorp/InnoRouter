// MARK: - RouterPlatform.swift
// InnoRouterCore - explicit native platform capability and adaptation contract
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Apple platform family compiling the current InnoRouter target.
public enum RouterPlatform: String, CaseIterable, Hashable, Sendable, Codable {
    case iOS
    case macCatalyst
    case macOS
    case tvOS
    case watchOS
    case visionOS
}

/// Native presentation option that a host may be unable to render.
public enum RouterPresentationOptionFeature: String, CaseIterable, Hashable, Sendable, Codable {
    case detents
    case selectedDetent
    case dragIndicator
    case compactAdaptation
    case backgroundInteraction
    case contentInteraction
    case cornerRadius
}

/// One platform-dependent router capability.
public enum RouterPlatformFeature: String, CaseIterable, Hashable, Sendable, Codable {
    case stackNavigation
    case tabs
    case splitView
    case windowScenes
    case immersiveSpace
    case distinctFullScreenCover
    case distinctPopover
    case presentationCustomization
    case tabBadgeVisuals
    case inspectorFileTransfer
}

/// Payload-safe record of a native rendering adaptation made by a host.
public enum RouterPlatformAdaptation: Hashable, Sendable, Codable {
    case presentationStyle(
        presentationID: UUID,
        requested: RouterPresentationStyle,
        effective: RouterPresentationStyle
    )
    case presentationOptionsIgnored(
        presentationID: UUID,
        options: [RouterPresentationOptionFeature]
    )
    case tabBadgeVisualUnavailable(scope: RouterScopeID, count: Int)
}

/// Compile-time platform capabilities used by hosts and available to apps.
///
/// The value describes InnoRouter's native rendering contract, not merely API
/// availability in an SDK. For example, macOS supports popovers generally,
/// while the router intentionally adapts route presentations to one sheet
/// surface there today.
public struct RouterPlatformCapabilities: Hashable, Sendable {
    public let platform: RouterPlatform
    public let supportedFeatures: Set<RouterPlatformFeature>

    private init(
        platform: RouterPlatform,
        supportedFeatures: Set<RouterPlatformFeature>
    ) {
        self.platform = platform
        self.supportedFeatures = supportedFeatures
    }

    /// Capabilities of the target compiling this module.
    public static var current: Self {
#if targetEnvironment(macCatalyst)
        declared(for: .macCatalyst)
#elseif os(iOS)
        declared(for: .iOS)
#elseif os(macOS)
        declared(for: .macOS)
#elseif os(tvOS)
        declared(for: .tvOS)
#elseif os(watchOS)
        declared(for: .watchOS)
#elseif os(visionOS)
        declared(for: .visionOS)
#else
#error("InnoRouter supports only declared Apple platforms")
#endif
    }

    /// InnoRouter's native rendering contract for `platform`.
    public static func declared(for platform: RouterPlatform) -> Self {
        switch platform {
        case .iOS:
            Self(
                platform: platform,
                supportedFeatures: [
                    .stackNavigation,
                    .tabs,
                    .splitView,
                    .windowScenes,
                    .distinctFullScreenCover,
                    .distinctPopover,
                    .presentationCustomization,
                    .tabBadgeVisuals,
                    .inspectorFileTransfer,
                ]
            )
        case .macCatalyst:
            Self(
                platform: platform,
                supportedFeatures: [
                    .stackNavigation,
                    .tabs,
                    .splitView,
                    .windowScenes,
                    .distinctPopover,
                    .presentationCustomization,
                    .tabBadgeVisuals,
                    .inspectorFileTransfer,
                ]
            )
        case .macOS:
            Self(
                platform: platform,
                supportedFeatures: [
                    .stackNavigation,
                    .tabs,
                    .splitView,
                    .windowScenes,
                    .tabBadgeVisuals,
                    .inspectorFileTransfer,
                ]
            )
        case .tvOS:
            Self(
                platform: platform,
                supportedFeatures: [
                    .stackNavigation,
                    .tabs,
                    .splitView,
                    .distinctFullScreenCover,
                ]
            )
        case .watchOS:
            Self(
                platform: platform,
                supportedFeatures: [
                    .stackNavigation,
                    .tabs,
                ]
            )
        case .visionOS:
            Self(
                platform: platform,
                supportedFeatures: [
                    .stackNavigation,
                    .tabs,
                    .splitView,
                    .windowScenes,
                    .immersiveSpace,
                    .tabBadgeVisuals,
                    .inspectorFileTransfer,
                ]
            )
        }
    }

    public func supports(_ feature: RouterPlatformFeature) -> Bool {
        supportedFeatures.contains(feature)
    }

    /// Native style that the current host renders for a requested style.
    public func effectivePresentationStyle(
        for requested: RouterPresentationStyle
    ) -> RouterPresentationStyle {
        switch requested {
        case .sheet:
            .sheet
        case .fullScreenCover:
            supports(.distinctFullScreenCover) ? .fullScreenCover : .sheet
        case .popover:
            supports(.distinctPopover) ? .popover : .sheet
        }
    }

    /// Adaptations a host must record when presenting the supplied value.
    public func adaptations<R: Route>(
        for presentation: RouterPresentation<R>
    ) -> [RouterPlatformAdaptation] {
        var adaptations: [RouterPlatformAdaptation] = []
        let effectiveStyle = effectivePresentationStyle(for: presentation.style)
        if effectiveStyle != presentation.style {
            adaptations.append(
                .presentationStyle(
                    presentationID: presentation.id,
                    requested: presentation.style,
                    effective: effectiveStyle
                )
            )
        }

        if !supports(.presentationCustomization) {
            let ignored = ignoredPresentationOptions(presentation.options)
            if !ignored.isEmpty {
                adaptations.append(
                    .presentationOptionsIgnored(
                        presentationID: presentation.id,
                        options: ignored
                    )
                )
            }
        }
        return adaptations
    }

    private func ignoredPresentationOptions(
        _ options: RouterPresentationOptions
    ) -> [RouterPresentationOptionFeature] {
        var ignored: [RouterPresentationOptionFeature] = []
        if !options.detents.isEmpty { ignored.append(.detents) }
        if options.selectedDetent != nil { ignored.append(.selectedDetent) }
        if options.dragIndicator != .automatic { ignored.append(.dragIndicator) }
        if options.compactAdaptation != .automatic { ignored.append(.compactAdaptation) }
        if options.backgroundInteraction != .automatic { ignored.append(.backgroundInteraction) }
        if options.contentInteraction != .automatic { ignored.append(.contentInteraction) }
        if options.cornerRadius != nil { ignored.append(.cornerRadius) }
        return ignored
    }
}
