/// The marker protocol every typed route must conform to.
///
/// `Route` is the bedrock identity that flows through every InnoRouter
/// surface — `RouteStack`, `NavigationCommand`, `NavigationStore`,
/// `ModalStore`, `FlowStore`, deep-link planners and the macro-generated
/// `CasePath` members. Concrete adopters are normally enums whose cases
/// describe the screens of a feature module.
///
/// ## Requirements
///
/// `Route` refines two existing protocols and adds nothing of its own:
///
/// - `Hashable` so the framework can store routes in `Set`s and use
///   them as `NavigationStack(value:)` identities.
/// - `Sendable` so the same route values can flow across actor
///   boundaries — middleware on a background actor, deep-link
///   pipelines on a `@MainActor`, telemetry sinks on `Task` actors —
///   without `@unchecked` escape hatches.
///
/// `Sendable` conformance for downstream generics is intentionally
/// unconditional: every `NavigationIntent`, `ModalIntent`, and
/// `FlowIntent` is `Sendable` because `Route: Sendable` already is.
///
/// ## Conforming
///
/// The recommended shape is a value-typed enum, optionally annotated
/// with `@Routable` to receive `CasePath` members for free:
///
/// ```swift
/// @Routable
/// enum AppRoute {
///     case home
///     case detail(id: String)
///     case profile(userID: UUID)
/// }
/// ```
///
/// The macro adds `Route` conformance, allowing Swift to synthesize
/// `Hashable` and `Sendable` when every associated value supports them.
/// Manual conformance also works:
///
/// ```swift
/// enum AppRoute: Route {
///     case home
///     case detail(id: String)
/// }
/// ```
///
/// Reference-typed routes (`class`, `actor`) are explicitly unsupported
/// — the SwiftUI authority layer relies on value-equality semantics
/// and the macros refuse to expand into anything but enum declarations.
public protocol Route: Hashable, Sendable {}
