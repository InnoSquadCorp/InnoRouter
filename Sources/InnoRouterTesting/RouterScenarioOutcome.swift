import InnoRouterCore

public enum RouterScenarioReplayError: Error, Hashable, Sendable {
    case incomplete(RouterScenarioCompleteness)
    case initialStateMismatch
    case invalidEventOrdering
    case invalidExpectedRevision(step: Int)
    case missingCancellationProvenance(step: Int)
    case unsupportedHistoryLifetime(step: Int)
    case unsupportedRequestSemantics(step: Int, code: RouterScenarioReplayLimitation)
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
    case missingFeatureResolver(namespaces: [String])
    case duplicateFeatureResolver(namespaces: [String])
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
        case .pendingLinkLifetime: .pendingLinkLifetime
        case .resourceLimit: .resourceLimit
        case .hostContract: .hostContract
        case .mutation: .mutation
        case .featureProjection: .featureProjection
        case .policy, .authorization: Self.policyKind(reason)
        case .busy: .busy
        case .coalesced: .coalesced
        case .superseded: .superseded
        case .queueOverflow: .queueOverflow
        case .policyTimedOut: .policyTimedOut
        case .policyCapacityExceeded: .policyCapacityExceeded
        case .deferralConflict, .deferralNotFound, .deferralCapacityExceeded,
             .deferralExpired, .deferralEvicted: Self.deferralKind(reason)
        case .staleState: .staleState
        case .cancelled: .cancelled
        case .missingAuthority: .missingAuthority
        }
    }

    private static func deferralKind(_ reason: RouterRejectionReason) -> Self {
        if case .deferralConflict = reason { return .deferralConflict }
        if case .deferralNotFound = reason { return .deferralNotFound }
        if case .deferralCapacityExceeded = reason { return .deferralCapacityExceeded }
        if case .deferralExpired = reason { return .deferralExpired }
        return .deferralEvicted
    }

    private static func policyKind(_ reason: RouterRejectionReason) -> Self {
        if case .authorization = reason { return .authorization }
        return .policy
    }
}
