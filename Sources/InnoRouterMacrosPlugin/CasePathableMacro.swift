// MARK: - CasePathableMacro.swift
// InnoRouter Macros - @CasePathable Implementation
// Copyright © 2025 Inno Squad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxBuilder
import SwiftDiagnostics

// MARK: - CasePathable Macro

/// `@CasePathable` synthesises a typed `CasePath` accessor for each case of
/// the attached enum. It is the `Route`-protocol-free counterpart of
/// `@Routable` — use it whenever an enum's cases need typed access but
/// the type itself is not a router-owned route.
///
/// ## Example
/// ```swift
/// @CasePathable
/// enum Destination {
///     case home
///     case profile(userId: String)
///     case settings(section: String, detail: Bool)
/// }
///
/// let dest: Destination = .profile(userId: "123")
/// dest[case: Destination.Cases.profile]  // Optional("123")
/// dest.is(Destination.Cases.home)        // false
/// ```
public struct CasePathableMacro: MemberMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        buildCasePathMembers(
            macroName: "CasePathable",
            node: node,
            declaration: declaration,
            context: context
        )
    }
}

// Diagnostics moved to `MacroDiagnostic.swift` (shared between
// @Routable and @CasePathable).
