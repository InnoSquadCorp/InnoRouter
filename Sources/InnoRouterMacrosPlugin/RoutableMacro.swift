// MARK: - RoutableMacro.swift
// InnoRouter Macros - @Routable Implementation
// Copyright © 2025 Inno Squad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxBuilder
import SwiftDiagnostics

// MARK: - Routable Macro

/// `@Routable` declares a `Route` enum with typed case-path helpers.
/// Use `@Router` for the macro-first SwiftUI composition path; use
/// `@Routable` when the route model needs case extraction without owning
/// destination views.
///
/// Attaching it to an enum synthesises:
/// - a nested `Cases` enum carrying a `CasePath` for every case
/// - the `Route` protocol conformance, so the type plugs into stores,
///   middleware, and deep-link planners without further boilerplate
/// - case-membership helpers (`is(_:)`, `subscript(case:)`)
///
/// Do not repeat `: Route` on the enum. The macro generates that conformance.
///
/// ## Example
/// ```swift
/// @Routable
/// enum HomeRoute {
///     case list
///     case detail(id: String)
///     case settings
/// }
///
/// let route = HomeRoute.detail(id: "42")
/// route[case: HomeRoute.Cases.detail]  // Optional("42")
/// route.is(HomeRoute.Cases.list)       // false
/// ```
public struct RoutableMacro: MemberMacro, ExtensionMacro {

    // MARK: - Member Macro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        buildCasePathMembers(
            macroName: "Routable",
            node: node,
            declaration: declaration,
            context: context
        )
    }

    // MARK: - Extension Macro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else { return [] }
        // Generic enums are diagnosed in the member-macro pass; skip synthesising
        // a `Route` conformance extension so the compiler doesn't see a partial
        // expansion alongside the diagnostic.
        guard enumDecl.genericParameterClause == nil else { return [] }

        let extensionDecl = try ExtensionDeclSyntax("extension \(type): Route {}")
        return [extensionDecl]
    }
}

// Diagnostics moved to `MacroDiagnostic.swift` (shared between
// @Routable and @CasePathable).
