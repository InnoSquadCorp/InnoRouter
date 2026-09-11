import Foundation

import InnoRouterCore

public struct RouterHistoryConfiguration: Hashable, Sendable {
    public var capacity: Int
    public var checkpointCapacity: Int
    public var sessionKey: String

    public init(
        capacity: Int = 50,
        checkpointCapacity: Int = 20,
        sessionKey: String = "default"
    ) {
        self.capacity = max(2, capacity)
        self.checkpointCapacity = max(1, checkpointCapacity)
        self.sessionKey = sessionKey
    }
}

public struct RouterHistoryEntry<R: Route>: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let navigationState: RouterState<R>
    public let sourceRevision: UInt64

    public init(
        id: UUID = UUID(),
        navigationState: RouterState<R>,
        sourceRevision: UInt64
    ) {
        self.id = id
        self.navigationState = navigationState
        self.sourceRevision = sourceRevision
    }
}

extension RouterHistoryEntry: Codable where R: Codable {}

public struct RouterHistoryCheckpoint<R: Route>: Identifiable, Hashable, Sendable {
    public let formatVersion: Int
    public let id: UUID
    public let name: String
    public let sessionKey: String
    public let entry: RouterHistoryEntry<R>

    public init(
        id: UUID = UUID(),
        name: String,
        sessionKey: String,
        entry: RouterHistoryEntry<R>
    ) {
        self.formatVersion = 1
        self.id = id
        self.name = name
        self.sessionKey = sessionKey
        self.entry = entry
    }
}

extension RouterHistoryCheckpoint: Codable where R: Codable {}

public enum RouterHistoryCheckpointCollisionStrategy: Hashable, Sendable {
    case reject
    case replace
}

public enum RouterHistoryFailure: Error, Hashable, Sendable {
    case stopped
    case cancelled
    case noPreviousEntry
    case noNextEntry
    case checkpointNotFound(String)
    case checkpointAlreadyExists(String)
    case checkpointCapacityExceeded(limit: Int)
    case invalidCheckpointName
    case unsupportedCheckpointVersion(Int)
    case sessionMismatch(expected: String, actual: String)
    case incompatibleTopology(RouterScopePath)
    case activePresentation(RouterScopePath)
    case validationFailed(RouterPartialRestorationError)
}

public enum RouterHistoryMoveResult<R: Route>: Hashable, Sendable {
    case completed(cursor: Int, transition: RouterOutcome<R>)
    case deferred(cursor: Int, transition: RouterOutcome<R>)
    case rejected(cursor: Int, transition: RouterOutcome<R>)
    case unavailable(cursor: Int, reason: RouterHistoryFailure)
}

package struct PendingRouterHistoryMove<R: Route> {
    let generation: UInt64
    let requestRootID: RouterTransitionID
    let entry: RouterHistoryEntry<R>
    let destinationCursor: Int?
}

package struct ActiveRouterHistoryMove<R: Route> {
    let task: Task<Void, Never>
    let continuation: CheckedContinuation<RouterHistoryMoveResult<R>, Never>
}

package extension RouterEvent {
    var transitionContext: RouterTransitionContext? {
        switch self {
        case .started(let transition):
            transition.context
        case .committed(_, _, _, _, let context),
             .unchanged(_, _, _, let context),
             .deferred(_, _, _, _, let context),
             .rejected(_, _, _, _, let context):
            context
        case .policyPrepared, .platformAdapted:
            nil
        }
    }
}
