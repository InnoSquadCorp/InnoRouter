// MARK: - CasePath.swift
// InnoRouter Macros - CasePath Type
// Copyright © 2025 Inno Squad. All rights reserved.

import Foundation

// MARK: - CasePath

/// A KeyPath-like accessor for a single enum case, paired with its
/// associated-value payload.
///
/// `CasePath` powers the SwiftUI typed-binding surface
/// (`ModalStore.binding(case:style:)`, `NavigationStore.path(for:)`)
/// and serves as the substrate for deep-link plan synthesis. Each
/// instance bundles two closures — `embed` (value → enum) and
/// `extract` (enum → optional value) — so the framework can both
/// observe and rewrite specific cases without exhaustively pattern
/// matching every other case.
///
/// ## Primary producer
///
/// Almost every `CasePath` in a real app is generated automatically
/// by `@Routable` or `@CasePathable`:
///
/// ```swift
/// @Routable
/// enum AppRoute {
///     case detail(id: String)
/// }
///
/// // Macro-emitted member, no manual code required.
/// let casePath = AppRoute.Cases.detail  // CasePath<AppRoute, String>
///
/// let route = casePath.embed("123")     // AppRoute.detail(id: "123")
/// casePath.extract(route)               // Optional("123")
/// ```
///
/// Constructing a `CasePath` by hand is valid but rarely necessary —
/// reach for it only when wrapping an enum whose declaration cannot
/// be annotated with the macros (for example, a type vended from a
/// pre-built binary framework).
///
/// ## Composition
///
/// `appending(path:)` chains two case paths so callers can drill into
/// nested cases (`Settings → Privacy → DataExport`) without
/// re-extracting at every level. Both `embed` and `extract` close
/// over `@Sendable` storage so chained paths remain safe to share
/// across actors.
public struct CasePath<Root, Value>: Sendable {

    /// Wraps an associated-value payload into the matching enum case.
    public let embed: @Sendable (Value) -> Root

    /// Extracts the associated-value payload from a matching enum case,
    /// returning `nil` when the root value is in a different case.
    public let extract: @Sendable (Root) -> Value?

    /// Creates a `CasePath` from a hand-written embed/extract pair.
    ///
    /// Most call sites should not need this initialiser — `@Routable`
    /// and `@CasePathable` generate the correct pair automatically. Use
    /// it only when wrapping an enum whose declaration cannot be macro-
    /// annotated (for example, a type vended from a binary framework).
    ///
    /// - Parameters:
    ///   - embed: Closure that lifts a `Value` payload into the
    ///     corresponding `Root` enum case.
    ///   - extract: Closure that returns the case payload, or `nil`
    ///     when `Root` is in a different case.
    public init(
        embed: @escaping @Sendable (Value) -> Root,
        extract: @escaping @Sendable (Root) -> Value?
    ) {
        self.embed = embed
        self.extract = extract
    }
}

// MARK: - Convenience Extensions

public extension CasePath where Value == Void {
    /// Embed shorthand for cases without an associated value.
    func callAsFunction() -> Root {
        embed(())
    }
}

public extension CasePath {
    /// Chains two case paths so callers can drill into nested cases
    /// (`Settings → Privacy → DataExport`) without re-extracting at
    /// every level.
    ///
    /// ```swift
    /// let path = Route.Cases.settings.appending(path: Settings.Cases.privacy)
    /// ```
    func appending<AppendedValue>(
        path: CasePath<Value, AppendedValue>
    ) -> CasePath<Root, AppendedValue> {
        CasePath<Root, AppendedValue>(
            embed: { self.embed(path.embed($0)) },
            extract: { self.extract($0).flatMap(path.extract) }
        )
    }
}
