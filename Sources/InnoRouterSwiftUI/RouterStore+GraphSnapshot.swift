import Foundation
import InnoRouterCore

public extension RouterStore {
    /// Encodes a stable-key graph snapshot without requiring runtime Codable.
    /// The codec validates its configured finite structure and payload limits.
    func snapshot(using codec: RouterGraphSnapshotCodec<R>) async throws -> Data {
        let captured = state
        return try await RouterSnapshotCodecExecutor(graphCodec: codec, resourceBudget: resourceBudget).encode(captured)
    }

    /// Decodes a graph DTO and applies it through the existing Store authority.
    /// Generation and revision are captured before decoding starts. No failed
    /// graph is silently retried using the legacy decoder or a guessed schema.
    func restore(
        from data: Data,
        using codec: RouterGraphSnapshotCodec<R>,
        tabTopology: RouterTabRestorationTopology? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterOutcome<R> {
        let capturedRevision = expectedRevision ?? revision
        let precondition = authorizationPrecondition(request: nil, existing: nil)
        let decoded = try await RouterSnapshotCodecExecutor(graphCodec: codec, resourceBudget: resourceBudget).decode(data)
        let prepared = try tabTopology?.reconciling(decoded) ?? decoded
        return await perform(
            .apply(RouterPlan(state: prepared)), context: .init(source: .restoration),
            expectedRevision: capturedRevision, bypassesPolicies: false,
            lifetimeMutation: .replaceAll, executionPrecondition: precondition
        )
    }
}
