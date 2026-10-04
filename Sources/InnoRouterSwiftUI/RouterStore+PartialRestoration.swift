// MARK: - RouterStore+PartialRestoration.swift
// InnoRouterSwiftUI - store adapter for app-validated partial restoration
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

public extension RouterStore where R: Codable {
    /// Decodes and migrates a snapshot, validates each route with the app,
    /// then applies one exact partial-restoration plan through normal policies.
    func restorePartially(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        validator: RouterPartialRestorationValidator<R>,
        validationTimeout: Duration? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterPartialRestorationOutcome<R> {
        try await restorePartially(
            from: data,
            using: codec,
            validator: validator,
            tabTopology: nil,
            validationTimeout: validationTimeout,
            expectedRevision: expectedRevision
        )
    }

    /// Decodes and migrates a snapshot, adds the tabs this application renders
    /// now, validates every route of the resulting candidate with the app, and
    /// applies one exact plan through normal policies.
    ///
    /// Reconciliation runs before validation, so the application sees the
    /// candidate that will actually be applied and nothing is added to it
    /// afterwards. Scopes created for tabs the snapshot predates are empty,
    /// so they contribute no routes to validate.
    func restorePartially(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        validator: RouterPartialRestorationValidator<R>,
        tabTopology: RouterTabRestorationTopology,
        validationTimeout: Duration? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterPartialRestorationOutcome<R> {
        try await restorePartially(
            from: data,
            using: codec,
            validator: validator,
            tabTopology: .some(tabTopology),
            validationTimeout: validationTimeout,
            expectedRevision: expectedRevision
        )
    }

    private func restorePartially(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        validator: RouterPartialRestorationValidator<R>,
        tabTopology: RouterTabRestorationTopology?,
        validationTimeout: Duration?,
        expectedRevision: UInt64?
    ) async throws -> RouterPartialRestorationOutcome<R> {
        let capturedRevision = expectedRevision ?? revision
        let executionPrecondition = authorizationPrecondition(request: nil, existing: nil)
        let decoded = try await RouterSnapshotCodecExecutor(codec: codec).decode(data)
        return try await restorePartially(
            decoded: decoded,
            validator: validator,
            tabTopology: tabTopology,
            validationTimeout: validationTimeout,
            expectedRevision: capturedRevision,
            executionPrecondition: executionPrecondition
        )
    }

    package func restorePartially(
        decoded: RouterState<R>,
        validator: RouterPartialRestorationValidator<R>,
        tabTopology: RouterTabRestorationTopology?,
        validationTimeout: Duration?,
        expectedRevision: UInt64,
        transitionID: RouterTransitionID? = nil,
        requestRootID: RouterTransitionID? = nil,
        executionPrecondition: RouterRequestPrecondition<R>? = nil
    ) async throws -> RouterPartialRestorationOutcome<R> {
        let executionPrecondition = authorizationPrecondition(request: nil, existing: executionPrecondition)
        let candidate = try tabTopology.map { try $0.reconciling(decoded) } ?? decoded
        let planned = try await preparePartialRestoration(
            candidate,
            validator: validator,
            operations: restorationOperations,
            timeout: validationTimeout,
            sleep: runtimeDependencies.sleep
        )
        let transition = await perform(
            .apply(RouterPlan(state: planned.0)),
            context: .init(source: .restoration),
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            transitionID: transitionID,
            requestRootID: requestRootID,
            lifetimeMutation: .replaceAll,
            executionPrecondition: executionPrecondition
        )
        let report = RouterPartialRestorationReport(
            entries: planned.1.entries,
            topologyChanges: tabTopology?.changes(from: decoded, to: planned.0) ?? []
        )
        return RouterPartialRestorationOutcome(report: report, transition: transition)
    }
}
