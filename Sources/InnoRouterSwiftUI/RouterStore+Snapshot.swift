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

    package func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        recovery: RouterSnapshotRecoveryPolicy<R>,
        expectedRevision: UInt64?,
        transitionID: RouterTransitionID? = nil,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws -> RouterRestorationOutcome<R> where R: Codable {
        let decoding = try await RouterSnapshotCodecExecutor(codec: codec).decode(
            data,
            recovery: recovery
        )
        let transition = await perform(
            .apply(RouterPlan(state: decoding.state)),
            context: .init(source: .restoration),
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            transitionID: transitionID,
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
