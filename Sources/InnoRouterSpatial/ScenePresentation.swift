import Foundation

import InnoRouterCore

/// Immersion style for an `ImmersiveSpace`-style scene presentation.
///
/// Mirrors SwiftUI's `ImmersionStyle` cases but lives in
/// ``InnoRouterSpatial`` as a plain value so the scene vocabulary remains
/// available on every platform InnoRouter supports. On visionOS the value
/// is part of a scene declaration contract validated by the scene host;
/// non-visionOS hosts simply never act on it.
public enum ImmersiveStyle: Sendable, Hashable, Codable {
    /// Mixed immersion — the user's passthrough environment stays visible
    /// around the app's content.
    case mixed

    /// Progressive immersion — the user dials the level of immersion with
    /// the digital crown between passthrough and full.
    case progressive

    /// Full immersion — the app replaces the passthrough environment.
    case full
}

/// Size hint for a volumetric scene, in metres.
///
/// visionOS apps can request a specific volume size for a
/// `WindowGroup` declared with `.windowStyle(.volumetric)`. Keeping the
/// value type in the opt-in spatial module lets the rest of that pipeline
/// reason about scene presentations without importing RealityKit. On
/// visionOS the value participates in scene declaration validation rather
/// than being passed dynamically to the environment opener.
public struct VolumetricSize: Sendable, Hashable, Codable {
    /// Extent along the x axis, in metres.
    public let x: Double

    /// Extent along the y axis, in metres.
    public let y: Double

    /// Extent along the z axis, in metres.
    public let z: Double

    /// Creates a volumetric size.
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A spatial or window-level scene presentation.
///
/// `ScenePresentation` is deliberately separate from ``RouteStep`` and
/// ``ModalPresentation`` because scene transitions are multi-scene events
/// (opening a new window, opening or dismissing an immersive space),
/// whereas ``RouteStep`` and ``ModalPresentation`` describe transitions
/// inside a single scene's navigation stack or modal layer.
///
/// Today every case only materialises on visionOS — the `SceneStore` /
/// scene-host pair in `InnoRouterSpatial` is gated to `#if os(visionOS)`.
/// On other platforms the type still compiles (it is SwiftUI-free) but no
/// host acts on it. This keeps the vocabulary future-proof: if Apple adds
/// equivalent multi-scene affordances on other platforms, the store /
/// host layer can grow without changing this enum.
public enum ScenePresentation<R: Route>: Sendable, Hashable {
    /// A regular window for `route`.
    case window(R, id: UUID = UUID())

    /// A volumetric window for `route`, with an optional declared size
    /// contract. On visionOS the host validates this against a
    /// `WindowGroup` declared with `.windowStyle(.volumetric)`.
    case volumetric(R, size: VolumetricSize? = nil, id: UUID = UUID())

    /// An immersive space for `route`, with the declared immersion
    /// style. On visionOS the host validates this against the
    /// corresponding `ImmersiveSpace` declaration before dispatch.
    case immersive(R, style: ImmersiveStyle, id: UUID = UUID())
}

// MARK: - Codable

extension ScenePresentation: Encodable where R: Encodable {}
extension ScenePresentation: Decodable where R: Decodable {}
