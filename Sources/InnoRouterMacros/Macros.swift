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
/// - synthesises `DestinationRoute` (and therefore `Route`) conformance
/// - generates the access-level-matched `static destination(for:)` witness
/// - synthesises `RouterTab` metadata when every case has `@TabItem`
///
/// Host the result with `RouterHost` and navigate from descendants with
/// `EnvironmentRouter`.
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
/// witness. Tab routers also diagnose partial, conditional, unavailable, or
/// associated-value cases at compile time. It warns for root-only enums and
/// redundant explicit `Route`, `DestinationRoute`, `RouterTab`, or
/// `CaseIterable` conformance.
@attached(memberAttribute)
@attached(
    extension,
    conformances: DestinationRoute, RouterTab,
    names: named(destination), named(allCases), named(title), named(systemImage)
)
public macro Router() = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "RouterMacro"
)

// MARK: - @TabItem

/// Marks a parameterless `@Router` enum case as a tab destination.
///
/// When any case carries `@TabItem`, every case in that router must carry one.
/// `@Router` then synthesises `RouterTab`, `CaseIterable`, and the tab metadata
/// witnesses used by `RouterTabHost`.
///
/// ```swift
/// @Router
/// enum AppTab {
///     @TabItem("Home", systemImage: "house")
///     case home
///
///     @TabItem("Settings", systemImage: "gear")
///     case settings
///
///     var destination: some View {
///         switch self {
///         case .home: HomeView()
///         case .settings: SettingsView()
///         }
///     }
/// }
/// ```
@attached(peer)
public macro TabItem(
    _ title: String,
    systemImage: String
) = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "TabItemMacro"
)

// MARK: - @Routable

/// Synthesises `CasePath` members and the `Route` protocol conformance on the
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
