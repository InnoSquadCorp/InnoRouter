// MARK: - NavigationExecutionResult.swift
// InnoRouterCore — shared shape for `NavigationBatchResult` and
// `NavigationTransactionResult`.
// Copyright © 2026 Inno Squad. All rights reserved.
//
// `NavigationBatchResult` and `NavigationTransactionResult` declare
// the same set of fields (requested / attempted commands, top-level
// results, stateBefore / stateAfter, success predicate) by hand.
// Tests, telemetry adapters, and middleware that want to write a
// generic helper over either type previously had to either branch
// on the concrete type or duplicate the helper.
//
// This protocol is the *common shape*: any new helper can take
// `some NavigationExecutionResult<R>` and read the shared fields.
// The concrete types keep their idiomatic-name accessors
// (`hasStoppedOnFailure`, `isCommitted`, `failureIndex`) — those
// are batch- or transaction-specific and intentionally not on the
// protocol.

/// A read-only contract shared by every navigation execution
/// outcome that aggregates multiple commands into a single
/// observation.
///
/// Conforming types ship today:
///
/// - ``NavigationBatchResult`` — per-step execution, single
///   coalesced observation, `hasStoppedOnFailure` reports whether
///   `stopOnFailure` cut the batch short.
/// - ``NavigationTransactionResult`` — atomic preview/commit
///   semantics, `isCommitted` reports the all-or-nothing outcome,
///   and `failureIndex` points at the first failing step on rollback.
///   Empty transactions are uncommitted with no failure index because
///   no command ran.
///
/// The protocol exposes the shared shape and a unified `isSuccess`
/// predicate so generic helpers (for example a logging middleware
/// that records every aggregate execution) can treat both types
/// uniformly.
///
/// New aggregate result types added in future minor releases are
/// expected to conform to this protocol so the shared shape stays
/// stable across the library.
public protocol NavigationExecutionResult<R>: Sendable, Equatable {

    /// The route type the underlying navigation engine operates on.
    associatedtype R: Route

    /// Commands originally requested for execution.
    var requestedCommands: [NavigationCommand<R>] { get }

    /// Effective commands actually passed to the navigation engine after
    /// middleware interception and rewriting, in attempt order. Interception
    /// cancellations are absent; attempts later discarded by a savepoint or
    /// transaction rollback remain present.
    var executedCommands: [NavigationCommand<R>] { get }

    /// Top-level results for requested commands reached before execution
    /// stopped, in request order. Composite commands, interception
    /// cancellations, and discarded attempts mean this array does not have a
    /// one-to-one index or count relationship with ``executedCommands``.
    var results: [NavigationResult<R>] { get }

    /// Navigation state before the aggregate execution started.
    var stateBefore: RouteStack<R> { get }

    /// Navigation state after the aggregate execution finished.
    ///
    /// For an all-or-nothing transaction that did not commit, this
    /// is the same snapshot as ``stateBefore``.
    var stateAfter: RouteStack<R> { get }

    /// Indicates whether the aggregate execution succeeded as a
    /// whole.
    ///
    /// - For batch executions, this reads as "every step
    ///   succeeded".
    /// - For transactional executions, this reads as "the
    ///   transaction committed".
    var isSuccess: Bool { get }
}

// MARK: - Conformance

extension NavigationBatchResult: NavigationExecutionResult {}

extension NavigationTransactionResult: NavigationExecutionResult {

    /// Mirrors ``isCommitted`` to satisfy ``NavigationExecutionResult``.
    /// A committed transaction is the transactional analogue of
    /// "every step succeeded" on a non-empty batch.
    public var isSuccess: Bool { isCommitted }
}
