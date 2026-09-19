// MARK: - RouterStore+Snapshot.swift
// InnoRouterSwiftUI - snapshot and exact-plan operations
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

package actor RouterSnapshotCodecExecutor<R: Route & Codable> {
    private let codec: RouterSnapshotCodec<R>

    package init(codec: RouterSnapshotCodec<R>) {
        self.codec = codec
    }

    package func encode(_ state: RouterState<R>) throws -> Data {
        try codec.encode(state)
    }

    package func decode(_ data: Data) throws -> RouterState<R> {
        try codec.decode(data)
    }

    package func decode(
        _ data: Data,
        recovery: RouterSnapshotRecoveryPolicy<R>
    ) throws -> RouterSnapshotDecodingResult<R> {
        try codec.decode(data, recovery: recovery)
    }
}

public extension RouterStore {
    /// Encodes the current complete state using the supplied version contract.
    func snapshot(
        using codec: RouterSnapshotCodec<R>
    ) async throws -> Data where R: Codable {
        let state = state
        return try await RouterSnapshotCodecExecutor(codec: codec).encode(state)
    }

    /// Decodes, migrates, validates, and applies a complete snapshot through
    /// normal router policies.
    func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterOutcome<R> where R: Codable {
        let restored = try await RouterSnapshotCodecExecutor(codec: codec).decode(data)
        return await perform(
            .apply(RouterPlan(state: restored)),
            context: .init(source: .restoration),
            expectedRevision: expectedRevision,
            bypassesPolicies: false
        )
    }

    /// Restores with an explicit recovery policy and preserves whether the
    /// applied state came from the snapshot or the caller's fallback.
    func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        recovery: RouterSnapshotRecoveryPolicy<R>,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterRestorationOutcome<R> where R: Codable {
        try await restore(
            from: data,
            using: codec,
            recovery: recovery,
            expectedRevision: expectedRevision,
            executionPrecondition: nil
        )
    }

    /// Restores a complete snapshot against the tab topology this application
    /// renders now.
    ///
    /// Unlike ``restore(from:using:expectedRevision:)``, which applies the
    /// snapshot exactly, this overload adds any tab in `tabTopology` that the
    /// snapshot predates, so a tab introduced since the snapshot was written
    /// is selectable. Scopes the snapshot already carries keep their path,
    /// presentation, and badge; scopes it lacks are created empty.
    ///
    /// Pass the topology of the catalog the host renders. Nothing is inferred
    /// from this store's initial state. A navigation committed after this
    /// request starts makes the decoded candidate stale.
    func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        tabTopology: RouterTabRestorationTopology,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterOutcome<R> where R: Codable {
        let capturedRevision = expectedRevision ?? revision
        let restored = try await RouterSnapshotCodecExecutor(codec: codec).decode(data)
        let prepared = try tabTopology.reconciling(restored)
        return await perform(
            .apply(RouterPlan(state: prepared)),
            context: .init(source: .restoration),
            expectedRevision: capturedRevision,
            bypassesPolicies: false
        )
    }

    /// Restores against an explicit tab topology, with an application recovery
    /// policy for an unreadable snapshot.
    ///
    /// A state produced by ``RouterSnapshotRecoveryPolicy/use(_:)`` is the
    /// application's final answer and is applied exactly. Tab reconciliation
    /// runs only on a state that actually decoded.
    func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        recovery: RouterSnapshotRecoveryPolicy<R>,
        tabTopology: RouterTabRestorationTopology,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterRestorationOutcome<R> where R: Codable {
        let capturedRevision = expectedRevision ?? revision
        return try await restore(
            from: data,
            using: codec,
            recovery: recovery,
            expectedRevision: capturedRevision,
            tabTopology: tabTopology,
            executionPrecondition: nil
        )
    }

    package func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        recovery: RouterSnapshotRecoveryPolicy<R>,
        expectedRevision: UInt64?,
        transitionID: RouterTransitionID? = nil,
        requestRootID: RouterTransitionID? = nil,
        tabTopology: RouterTabRestorationTopology? = nil,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws -> RouterRestorationOutcome<R> where R: Codable {
        let decoding = try await RouterSnapshotCodecExecutor(codec: codec).decode(
            data,
            recovery: recovery
        )
        let prepared: RouterState<R>
        switch (decoding, tabTopology) {
        case (.restored(let state), .some(let topology)):
            prepared = try topology.reconciling(state)
        case (.restored(let state), .none):
            prepared = state
        case (.recovered(let state, _), _):
            // The application already chose this state. Reconciling it would
            // override the fallback it deliberately returned.
            prepared = state
        }
        let transition = await perform(
            .apply(RouterPlan(state: prepared)),
            context: .init(source: .restoration),
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            transitionID: transitionID,
            requestRootID: requestRootID,
            executionPrecondition: executionPrecondition
        )
        return RouterRestorationOutcome(
            decoding: decoding,
            transition: transition
        )
    }

    /// Builds and applies multiple exact-state changes as one transition.
    func transaction(
        @RouterPlanBuilder<R> _ build: () -> [RouterPlanStep<R>]
    ) async throws -> RouterOutcome<R> {
        let plan = try RouterPlan(from: state, build)
        return await perform(.apply(plan))
    }
}
