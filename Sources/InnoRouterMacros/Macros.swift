// MARK: - Macros.swift
// InnoRouter Macros - Public Macro Declarations
// Copyright © 2025 Inno Squad. All rights reserved.

@_exported import InnoRouterCore
@_exported import InnoRouterSwiftUI

// MARK: - @Router

/// Turns an enum with a `destination` view into a locally hostable router.
///
/// `@Router` is the macro-first entry point for SwiftUI applications. Add the
/// `InnoRouter` product, use `import InnoRouter`, and declare route cases plus
/// one get-only instance property named `destination`. The macro:
///
/// - adds `@MainActor` and `@ViewBuilder` to that property when needed
/// - synthesises ``DestinationRoute`` (and therefore ``Route``) conformance
/// - generates the access-level-matched `static destination(for:)` witness
///
/// Host the result with ``RouterHost`` and navigate from descendants with
/// ``EnvironmentRouter``.
///
/// ```swift
/// import SwiftUI
/// import InnoRouter
///
/// @Router
/// enum AppRoute {
///     case settings
///     case detail(id: String)
///
///     var destination: some View {
///         switch self {
///         case .settings:
///             SettingsView()
///         case .detail(let id):
///             DetailView(id: id)
///         }
///     }
/// }
///
/// struct AppRoot: View {
///     var body: some View {
///         RouterHost(AppRoute.self) {
///             Text("Home")
///         }
///     }
/// }
/// ```
///
/// The macro emits actionable compiler diagnostics when it is attached to a
/// non-enum declaration, when `destination` is missing or has the wrong shape,
/// or when a manual `static destination(for:)` conflicts with the generated
/// witness. It warns for root-only enums and redundant explicit `Route` or
/// `DestinationRoute` conformance.
@attached(memberAttribute)
@attached(
    extension,
    conformances: DestinationRoute,
    names: named(destination)
)
public macro Router() = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "RouterMacro"
)

// MARK: - @Routable

/// Synthesises `CasePath` members and the ``Route`` protocol conformance on the
/// attached enum.
///
/// Use `@Router` for the default macro-first SwiftUI composition. Use
/// `@Routable` when a route model needs typed case extraction but owns no
/// destination view. Do not also write `: Route`; the macro supplies that
/// conformance.
///
/// ## What gets generated
/// - a nested `Cases` enum carrying a `CasePath` for every case
/// - an `is(_:)` method for case-membership checks
/// - a `subscript(case:)` for typed associated-value extraction
/// - `Route` conformance (which already requires `Hashable & Sendable`)
///
/// ## Example
/// ```swift
/// @Routable
/// enum HomeRoute {
///     case list
///     case detail(id: String)
///     case settings(section: SettingsSection)
/// }
///
/// // Usage
/// let route: HomeRoute = .detail(id: "123")
/// route[case: HomeRoute.Cases.detail]  // Optional("123")
/// route.is(HomeRoute.Cases.list)       // false
/// HomeRoute.Cases.detail               // CasePath<HomeRoute, String>
/// ```
@attached(member, names: named(Cases), named(`is`), named(subscript))
@attached(extension, conformances: Route)
public macro Routable() = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "RoutableMacro"
)

// MARK: - @CasePathable

/// Adds `CasePath` accessors to a regular enum without imposing the
/// `Route` conformance. `@CasePathable` is the lightweight counterpart
/// of `@Routable` — reach for it when a type's cases need typed access
/// but the type itself is not a router-owned route.
///
/// ## Example
/// ```swift
/// @CasePathable
/// enum Destination {
///     case home
///     case profile(userId: String)
/// }
///
/// let destination: Destination = .profile(userId: "42")
/// destination[case: Destination.Cases.profile]  // Optional("42")
/// destination.is(Destination.Cases.home)        // false
/// ```
@attached(member, names: named(Cases), named(`is`), named(subscript))
public macro CasePathable() = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "CasePathableMacro"
)
