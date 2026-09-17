// MARK: - MacroDiagnostic.swift
// InnoRouterMacrosPlugin - shared diagnostic + FixIt plumbing
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// Shared diagnostic payload for every InnoRouter macro.
///
/// Both ``RoutableMacro`` and ``CasePathableMacro`` emit the same
/// family of diagnostics, so we centralise the `DiagnosticMessage` +
/// `FixItMessage` machinery here instead of duplicating it per macro.
enum MacroDiagnostic: DiagnosticMessage {
    /// Declaration that the macro was attached to is not an enum.
    case requiresEnum(macroName: String)
    /// Declaration is an enum but has no cases — expansion produces
    /// nothing useful; surfaced as an error in 4.0.
    case emptyEnum(macroName: String)
    /// Declaration is a generic enum. The generated `CasePath<Self, T>`
    /// members cannot propagate the parent's generic parameters into a
    /// nested `enum Cases`, so expansion is rejected as an error.
    case unsupportedGenericEnum(macroName: String)

    var severity: DiagnosticSeverity {
        switch self {
        case .requiresEnum: return .error
        // Promoted from .warning to .error in 4.0.0. A `@Routable` /
        // `@CasePathable` macro applied to an empty enum produces zero
        // members; the warning was easy to miss in noisy build logs and
        // turned the macro into a silent no-op. Failing the build
        // forces the author to either add a case or remove the macro,
        // which matches every other macro diagnostic's severity in
        // this plugin.
        case .emptyEnum: return .error
        case .unsupportedGenericEnum: return .error
        }
    }

    /// Stable, searchable error code attached to every InnoRouter
    /// macro diagnostic. The format `InnoRouterMacro.E###` is meant
    /// to be grep-friendly across build logs, issue trackers, and
    /// localized release notes; the numeric part will not be
    /// recycled when a case is removed.
    var errorCode: String {
        switch self {
        case .requiresEnum: return "InnoRouterMacro.E001"
        case .emptyEnum: return "InnoRouterMacro.E002"
        case .unsupportedGenericEnum: return "InnoRouterMacro.E003"
        }
    }

    var message: String {
        let prefix = "[\(errorCode)] "
        switch self {
        case .requiresEnum(let name):
            return prefix + "@\(name) can only be applied to enum declarations"
        case .emptyEnum(let name):
            return prefix + "@\(name) applied to an enum with no cases produces no case paths — consider adding at least one case or removing the macro"
        case .unsupportedGenericEnum(let name):
            return prefix + "@\(name) does not support generic enum declarations. Generic parameters cannot be propagated through the generated `CasePath` members. Consider separating generic cases into a non-generic wrapper enum."
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .requiresEnum:
            return MessageID(domain: "InnoRouterMacros", id: "requiresEnum")
        case .emptyEnum:
            return MessageID(domain: "InnoRouterMacros", id: "emptyEnum")
        case .unsupportedGenericEnum:
            return MessageID(domain: "InnoRouterMacros", id: "unsupportedGenericEnum")
        }
    }
}

/// FixIt payload that accompanies ``MacroDiagnostic/requiresEnum`` when
/// the misapplied declaration is a `struct` or `class` — the two
/// keywords we can confidently suggest replacing with `enum`. Other
/// declaration kinds (protocol, actor, extension) get the diagnostic
/// without a FixIt because the shape change is too large to preview.
struct ReplaceKeywordWithEnumFixIt: FixItMessage {
    let originalKeyword: String

    var message: String {
        "Change `\(originalKeyword)` to `enum`"
    }

    var fixItID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "replaceKeywordWithEnum")
    }
}

/// Note attached to ``MacroDiagnostic/requiresEnum`` when the
/// misapplied declaration is a `protocol` or `actor`. These shapes
/// differ from `enum` enough that a one-keyword FixIt would silently
/// erase important semantics (witness tables, isolation), so the
/// macro emits a refactor hint instead of an automated rewrite.
struct RequiresEnumManualRefactorNote: NoteMessage {
    let originalKeyword: String

    var message: String {
        "Refactor manually — declaration shape differs from enum (`\(originalKeyword)` cannot be safely auto-replaced)."
    }

    var fixItID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "requiresEnumManualRefactor")
    }

    var noteID: MessageID { fixItID }
}

/// Emits the "must be applied to an enum" diagnostic and attaches a
/// keyword-replacement FixIt when the misapplied declaration is a
/// `struct` or `class`. For `protocol` / `actor` declarations the
/// diagnostic carries a manual-refactor note instead, because those
/// shapes cannot be safely auto-rewritten as enums.
func emitRequiresEnumDiagnostic(
    macroName: String,
    node: AttributeSyntax,
    declaration: some DeclGroupSyntax,
    context: some MacroExpansionContext
) {
    let fixIts = makeRequiresEnumFixIts(for: declaration)
    let notes = makeRequiresEnumNotes(for: declaration, attachedTo: node)
    context.diagnose(
        Diagnostic(
            node: node,
            message: MacroDiagnostic.requiresEnum(macroName: macroName),
            notes: notes,
            fixIts: fixIts
        )
    )
}

/// Emits the empty-enum error.
func emitEmptyEnumDiagnostic(
    macroName: String,
    node: AttributeSyntax,
    context: some MacroExpansionContext
) {
    context.diagnose(
        Diagnostic(
            node: node,
            message: MacroDiagnostic.emptyEnum(macroName: macroName)
        )
    )
}

/// Emits the "generic enums are not supported" diagnostic. The diagnostic is
/// pinned to the enum's generic parameter clause when available so the
/// compiler error highlights the offending `<...>` rather than the macro
/// attribute itself.
func emitUnsupportedGenericEnumDiagnostic(
    macroName: String,
    node: AttributeSyntax,
    enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) {
    let anchor: SyntaxProtocol = enumDecl.genericParameterClause ?? Syntax(node)
    context.diagnose(
        Diagnostic(
            node: anchor,
            message: MacroDiagnostic.unsupportedGenericEnum(macroName: macroName)
        )
    )
}

private func makeRequiresEnumFixIts(
    for declaration: some DeclGroupSyntax
) -> [FixIt] {
    if let structDecl = declaration.as(StructDeclSyntax.self) {
        return [keywordReplacementFixIt(
            original: structDecl.structKeyword,
            originalKeyword: "struct"
        )]
    }
    if let classDecl = declaration.as(ClassDeclSyntax.self) {
        return [keywordReplacementFixIt(
            original: classDecl.classKeyword,
            originalKeyword: "class"
        )]
    }
    return []
}

private func makeRequiresEnumNotes(
    for declaration: some DeclGroupSyntax,
    attachedTo node: AttributeSyntax
) -> [Note] {
    if let protocolDecl = declaration.as(ProtocolDeclSyntax.self) {
        return [Note(
            node: Syntax(protocolDecl.protocolKeyword),
            message: RequiresEnumManualRefactorNote(originalKeyword: "protocol")
        )]
    }
    if let actorDecl = declaration.as(ActorDeclSyntax.self) {
        return [Note(
            node: Syntax(actorDecl.actorKeyword),
            message: RequiresEnumManualRefactorNote(originalKeyword: "actor")
        )]
    }
    return []
}

private func keywordReplacementFixIt(
    original: TokenSyntax,
    originalKeyword: String
) -> FixIt {
    let replacement = TokenSyntax(
        .keyword(.enum),
        leadingTrivia: original.leadingTrivia,
        trailingTrivia: original.trailingTrivia,
        presence: .present
    )
    return FixIt(
        message: ReplaceKeywordWithEnumFixIt(originalKeyword: originalKeyword),
        changes: [.replace(oldNode: Syntax(original), newNode: Syntax(replacement))]
    )
}

// MARK: - Redundant conformance removal

/// FixIt payload for the `redundant…Conformance` warnings.
///
/// Each of those diagnostics already tells the author to "remove the explicit
/// conformance" and is anchored on the exact ``InheritanceClauseSyntax``, so
/// the edit is fully mechanical and worth offering as a FixIt.
struct RemoveRedundantConformanceFixIt: FixItMessage {
    let conformanceName: String

    var message: String {
        "Remove the redundant `\(conformanceName)` conformance"
    }

    var fixItID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "removeRedundantConformance")
    }
}

/// Builds a FixIt that drops `conformanceName` from `clause`.
///
/// The clause is rewritten as text rather than as a node so the three shapes
/// collapse to one code path: dropping the only conformance has to take the
/// colon with it (`enum E: Route {` → `enum E {`), while dropping one of
/// several has to take exactly one separating comma, whichever side it sits on
/// (`enum E: Route, Codable {` → `enum E: Codable {`).
///
/// Returns `nil` when the clause does not actually list `conformanceName`, so a
/// caller that misidentifies the conformance emits its warning without an edit
/// rather than a wrong one.
func removeConformanceFixIt(
    named conformanceName: String,
    from clause: InheritanceClauseSyntax,
    in enclosing: some SyntaxProtocol
) -> FixIt? {
    let remaining = clause.inheritedTypes.filter { inherited in
        inherited.type.trimmedDescription
            .split(separator: ".")
            .last
            .map(String.init) != conformanceName
    }
    guard remaining.count != clause.inheritedTypes.count else { return nil }

    let replacement = remaining.isEmpty
        ? ""
        : ": " + remaining
            .map { $0.type.trimmedDescription }
            .joined(separator: ", ")

    return FixIt(
        message: RemoveRedundantConformanceFixIt(conformanceName: conformanceName),
        changes: [
            .replaceText(
                range: clause.positionAfterSkippingLeadingTrivia
                    ..< clause.endPositionBeforeTrailingTrivia,
                with: replacement,
                in: Syntax(enclosing)
            ),
        ]
    )
}

// MARK: - Duplicate marker removal

/// FixIt payload for the `duplicate…` marker diagnostics.
struct RemoveDuplicateAttributeFixIt: FixItMessage {
    let attributeName: String
    let duplicateCount: Int

    var message: String {
        duplicateCount == 1
            ? "Remove the duplicate `@\(attributeName)`"
            : "Remove the \(duplicateCount) duplicate `@\(attributeName)` attributes"
    }

    var fixItID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "removeDuplicateAttribute")
    }
}

/// Where to anchor a duplicate-marker diagnostic, and the edit that resolves it.
struct DuplicateAttributeDiagnosis {
    /// The first redundant marker — what the author should look at.
    let anchor: AttributeSyntax
    /// Deletes every redundant marker, keeping the first.
    let fixIt: FixIt

    var fixIts: [FixIt] { [fixIt] }
}

/// Describes the duplicate markers in `attributes`, or `nil` when there is at
/// most one.
///
/// Every `duplicate…` diagnostic previously anchored on `attributes[1]` from
/// inside the `else` branch of `guard attributes.count == 1`. That branch also
/// runs for an empty list, so the subscript was an out-of-bounds trap — a
/// compiler-plugin crash — held off only by each caller pre-filtering to
/// annotated declarations. Taking the list and reporting `nil` when there is
/// nothing to diagnose removes the trap regardless of how callers change.
///
/// The removal range starts at `position`, so the marker's *leading* trivia
/// goes with it. That separator is what joins it to the marker before:
/// `@TabItem @TabItem case` loses the space, and a marker on its own line
/// loses the newline and indent that introduced it. Ending at
/// `endPositionBeforeTrailingTrivia` leaves the line break that belongs to
/// whatever follows, so neither a blank line nor a run-together line is left
/// behind.
func duplicateAttributeDiagnosis(
    _ attributes: [AttributeSyntax],
    in enclosing: some SyntaxProtocol
) -> DuplicateAttributeDiagnosis? {
    let duplicates = Array(attributes.dropFirst())
    guard let anchor = duplicates.first else { return nil }

    let name = anchor.attributeName.trimmedDescription
        .split(separator: ".")
        .last
        .map(String.init) ?? anchor.attributeName.trimmedDescription

    return DuplicateAttributeDiagnosis(
        anchor: anchor,
        fixIt: FixIt(
            message: RemoveDuplicateAttributeFixIt(
                attributeName: name,
                duplicateCount: duplicates.count
            ),
            changes: duplicates.map { duplicate in
                .replaceText(
                    range: duplicate.position
                        ..< duplicate.endPositionBeforeTrailingTrivia,
                    with: "",
                    in: Syntax(enclosing)
                )
            }
        )
    )
}

// MARK: - Misplaced marker removal

/// FixIt payload for the `requires…` placement diagnostics.
struct RemoveMisplacedAttributeFixIt: FixItMessage {
    let attributeName: String

    var message: String { "Remove `@\(attributeName)`" }

    var fixItID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "removeMisplacedAttribute")
    }
}

/// Builds a FixIt that deletes `attribute` from whatever it is attached to.
///
/// Used by the `requiresCase` diagnostics, where a marker sits on a
/// declaration that is not an enum case. Removing it is the whole remedy —
/// there is nothing for the macro to attach to and nothing to preserve.
///
/// Trivia is taken the same way as duplicate-marker removal: from `position`,
/// so the separator that introduced the attribute goes with it, to
/// `endPositionBeforeTrailingTrivia`, so the break belonging to the
/// declaration stays.
func removeMisplacedAttributeFixIt(
    _ attribute: AttributeSyntax,
    in enclosing: some SyntaxProtocol
) -> FixIt {
    let name = attribute.attributeName.trimmedDescription
        .split(separator: ".")
        .last
        .map(String.init) ?? attribute.attributeName.trimmedDescription

    return FixIt(
        message: RemoveMisplacedAttributeFixIt(attributeName: name),
        changes: [
            .replaceText(
                range: attribute.position ..< attribute.endPositionBeforeTrailingTrivia,
                with: "",
                in: Syntax(enclosing)
            ),
        ]
    )
}

// MARK: - Unused attribute argument removal

/// FixIt payload for arguments an attribute no longer acts on.
struct RemoveAttributeArgumentsFixIt: FixItMessage {
    let labels: [String]

    var message: String {
        labels.count == 1
            ? "Remove `\(labels[0]):`"
            : "Remove " + labels.map { "`\($0):`" }.joined(separator: " and ")
    }

    var fixItID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "removeAttributeArguments")
    }
}

/// Builds a FixIt dropping the `labels` arguments from `attribute`.
///
/// Used by `unusedAllowlist`, where `@Router` carries deep-link allowlists but
/// the enum declares no `@DeepLink` case, so the allowlists have no effect.
/// Arguments the attribute still acts on — `inspectorCatalog:`, say — are kept,
/// and the parentheses are dropped only when nothing is left inside them.
///
/// Returns `nil` when none of `labels` is present, so a caller that
/// misidentifies the arguments warns without offering a wrong edit.
func removeAttributeArgumentsFixIt(
    _ attribute: AttributeSyntax,
    labels: [String],
    in enclosing: some SyntaxProtocol
) -> FixIt? {
    guard case .argumentList(let arguments) = attribute.arguments,
          let leftParen = attribute.leftParen,
          let rightParen = attribute.rightParen
    else {
        return nil
    }
    let removedLabels = arguments.compactMap { argument -> String? in
        guard let label = argument.label?.text, labels.contains(label) else { return nil }
        return label
    }
    guard !removedLabels.isEmpty else { return nil }

    let remaining = arguments.filter { argument in
        guard let label = argument.label?.text else { return true }
        return !labels.contains(label)
    }
    let replacement = remaining.isEmpty
        ? ""
        : "(" + remaining
            .map { "\($0.label.map { "\($0.text): " } ?? "")\($0.expression.trimmedDescription)" }
            .joined(separator: ", ") + ")"

    return FixIt(
        message: RemoveAttributeArgumentsFixIt(labels: removedLabels),
        changes: [
            .replaceText(
                range: leftParen.position ..< rightParen.endPosition,
                with: replacement,
                in: Syntax(enclosing)
            ),
        ]
    )
}
