import Foundation
import InnoRouterCore

/// One executor boundary for both persistence formats. This owns no Store or
/// storage and grants no permission to apply a decoded state.
package actor RouterSnapshotCodecExecutor<R: Route> {
    private let encodeOperation: @Sendable (RouterState<R>) throws -> Data
    private let decodeOperation: @Sendable (Data) throws -> RouterState<R>
    private let recoveryOperation: @Sendable (Data, RouterSnapshotRecoveryPolicy<R>) throws -> RouterSnapshotDecodingResult<R>

    package init(codec: RouterSnapshotCodec<R>, resourceBudget: RouterResourceBudget? = nil) where R: Codable {
        let admitted = Result { try resourceBudget.map { try codec.constrained(to: $0) } ?? codec }
        encodeOperation = { try admitted.get().encode($0) }
        decodeOperation = { try admitted.get().decode($0) }
        recoveryOperation = { try admitted.get().decode($0, recovery: $1) }
    }

    package init(graphCodec: RouterGraphSnapshotCodec<R>, resourceBudget: RouterResourceBudget? = nil) {
        let admitted = Result { try resourceBudget.map { try graphCodec.constrained(to: $0) } ?? graphCodec }
        encodeOperation = { try admitted.get().encode($0) }
        decodeOperation = { try admitted.get().decode($0) }
        // Graph failures retain their actual typed code. They never trigger a
        // legacy decoder or get reinterpreted as a legacy recovery failure.
        recoveryOperation = { data, _ in .restored(try admitted.get().decode(data)) }
    }

    package func encode(_ state: RouterState<R>) throws -> Data {
        try encodeOperation(state)
    }

    package func decode(_ data: Data) throws -> RouterState<R> {
        try decodeOperation(data)
    }

    package func decode(
        _ data: Data,
        recovery: RouterSnapshotRecoveryPolicy<R>
    ) throws -> RouterSnapshotDecodingResult<R> {
        try recoveryOperation(data, recovery)
    }
}
