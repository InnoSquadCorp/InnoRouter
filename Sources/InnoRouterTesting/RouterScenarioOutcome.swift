import InnoRouterCore

public enum RouterScenarioReplayError: Error, Hashable, Sendable {
    case incomplete(RouterScenarioCompleteness)
    case initialStateMismatch
    case invalidEventOrdering
    case invalidExpectedRevision(step: Int)
    case missingCancellationProvenance(step: Int)
    case unsupportedHistoryLifetime(step: Int)
    case missingExpectation(step: Int)
    case stateMismatch(step: Int)
    case revisionBeforeCaptureBaseline(step: Int)
    case revisionMismatch(step: Int, expectedDelta: UInt64, actualDelta: UInt64)
    case terminalMismatch(
        step: Int,
        expected: RouterScenarioTerminal,
        actual: RouterScenarioTerminal
    )
    case rejectionMismatch(
        step: Int,
        expected: RouterScenarioRejectionKind,
        actual: RouterScenarioRejectionKind?
    )
    case routeSchemaMismatch(expected: String, actual: String)
    case environmentMismatch(expectedID: String, expectedVersion: String)
    case missingDependency(id: String, version: String)
    case missingDependencyCapability(dependencyID: String, capability: String)
    case missingReplayCapability(RouterScenarioReplayCapability)
    case unsupportedExternalEffect(String)
}

public extension RouterScenarioTerminal {
    init<R>(_ outcome: RouterOutcome<R>) {
        self = switch outcome {
        case .applied: .applied
        case .unchanged: .unchanged
        case .deferred: .deferred
        case .rejected: .rejected
        }
    }
}

public extension RouterScenarioRejectionKind {
    init(_ reason: RouterRejectionReason) {
        self = switch reason {
        case .mutation: .mutation
        case .featureProjection: .featureProjection
        case .policy: .policy
        case .busy: .busy
        case .coalesced: .coalesced
        case .superseded: .superseded
        case .queueOverflow: .queueOverflow
        case .policyTimedOut: .policyTimedOut
        case .deferralConflict: .deferralConflict
        case .deferralNotFound: .deferralNotFound
        case .deferralCapacityExceeded: .deferralCapacityExceeded
        case .deferralExpired: .deferralExpired
        case .deferralEvicted: .deferralEvicted
        case .staleState: .staleState
        case .cancelled: .cancelled
        case .missingAuthority: .missingAuthority
        }
    }
}
