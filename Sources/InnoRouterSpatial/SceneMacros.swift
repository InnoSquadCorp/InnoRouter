// MARK: - SceneMacros.swift
// InnoRouterSpatial - Public macro-first scene declarations
// Copyright © 2026 Inno Squad. All rights reserved.

@_exported import InnoRouterSwiftUI

/// Compile-time style metadata accepted by ``Scene(_:id:)``.
///
/// The values are declaration input for `@SceneRouter`; application code does
/// not need to switch over them at runtime. `@SceneRouter` converts the metadata
/// into the corresponding `WindowGroup`, volumetric window, or
/// `ImmersiveSpace` declaration.
public enum SpatialSceneStyle: Sendable, Hashable {
    /// A regular window scene.
    case window

    /// A volumetric window with dimensions in metres.
    case volumetric(width: Double, height: Double, depth: Double)

    /// An immersive space with the requested immersion style.
    case immersive(style: ImmersiveStyle)
}

/// Turns an enum into the macro-first route inventory for app-level scenes.
///
/// Add exactly one ``Scene(_:id:)`` annotation to each parameterless case and
/// provide one get-only `var destination: some View`. The first declared case
/// becomes the primary scene host; later cases become lifecycle anchors. An
/// explicit `id` is optional and defaults to the case name.
///
/// ```swift
/// @SceneRouter
/// enum AppScene {
///     @Scene(.window)
///     case main
///
///     @Scene(.volumetric(width: 0.6, height: 0.4, depth: 0.4))
///     case model
///
///     @Scene(.immersive(style: .mixed))
///     case theatre
///
///     var destination: some View {
///         switch self {
///         case .main: MainView()
///         case .model: ModelView()
///         case .theatre: TheatreView()
///         }
///     }
/// }
/// ```
@attached(memberAttribute)
@attached(
    extension,
    conformances: DestinationRoute,
    names: named(destination)
)
public macro SceneRouter() = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "SceneRouterMacro"
)

/// Declares the SwiftUI scene style for one parameterless `@SceneRouter` case.
///
/// Omit `id` for the common case. Supply a stable literal only when the scene
/// identifier must remain unchanged while its Swift case name evolves.
@attached(peer)
public macro Scene(
    _ style: SpatialSceneStyle,
    id: String? = nil
) = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "SceneMacro"
)
