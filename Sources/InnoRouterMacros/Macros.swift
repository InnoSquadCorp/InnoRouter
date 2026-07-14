// MARK: - Macros.swift
// InnoRouter Macros - Public Macro Declarations
// Copyright © 2025 Inno Squad. All rights reserved.

@_exported import InnoRouterCore
@_exported import InnoRouterSwiftUI

// MARK: - @Router

/// Turns an enum with a `destination` view into a locally hostable router.
///
/// Declare route cases and an instance destination property. `@Router` adds
/// the result-builder and actor annotations, then synthesises the
/// ``DestinationRoute`` conformance used by `RouterHost`.
///
/// ```swift
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
/// ```
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

/// Synthesises `CasePath` members and the `Route` protocol conformance
/// on the attached enum.
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
/// enum HomeRoute: Route {
///     case list
///     case detail(id: String)
///     case settings(section: SettingsSection)
/// }
///
/// // Usage
/// let route: HomeRoute = .detail(id: "123")
/// route[case: HomeRoute.Cases.detail]  // Optional("123")
/// route.is(HomeRoute.Cases.list)       // false
/// HomeRoute.Cases.detail          // CasePath<HomeRoute, String>
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
/// ```
@attached(member, names: named(Cases), named(`is`), named(subscript))
public macro CasePathable() = #externalMacro(
    module: "InnoRouterMacrosPlugin",
    type: "CasePathableMacro"
)
