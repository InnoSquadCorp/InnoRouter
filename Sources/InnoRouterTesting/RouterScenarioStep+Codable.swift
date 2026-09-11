import Foundation

import InnoRouterCore

extension RouterScenarioStep {
    private enum CodingKeys: String, CodingKey {
        case requestID
        case submissionIndex
        case submissionEventIndex
        case terminalEventIndex
        case action
        case context
        case requestSemantics
        case expectedRevision
        case cancellationOrigin
        case observedState
        case observedRevision
        case observedTerminal
        case observedRejection
        case observedDeferralID
        case expectation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.expectedRevision) else {
            throw DecodingError.keyNotFound(
                CodingKeys.expectedRevision,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Scenario format 7 requires expectedRevision, including null."
                )
            )
        }
        self.requestID = try container.decode(RouterTransitionID.self, forKey: .requestID)
        self.submissionIndex = try container.decode(Int.self, forKey: .submissionIndex)
        self.submissionEventIndex = try container.decode(Int.self, forKey: .submissionEventIndex)
        self.terminalEventIndex = try container.decode(Int.self, forKey: .terminalEventIndex)
        self.action = try container.decode(RouterAction<R>.self, forKey: .action)
        self.context = try container.decode(RouterTransitionContext.self, forKey: .context)
        self.requestSemantics = try container.decode(
            RouterScenarioRequestSemantics<R>.self,
            forKey: .requestSemantics
        )
        self.expectedRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .expectedRevision
        )
        self.cancellationOrigin = try container.decode(
            RouterScenarioCancellationOrigin.self,
            forKey: .cancellationOrigin
        )
        self.observedState = try container.decode(RouterState<R>.self, forKey: .observedState)
        self.observedRevision = try container.decode(UInt64.self, forKey: .observedRevision)
        self.observedTerminal = try container.decode(
            RouterScenarioTerminal.self,
            forKey: .observedTerminal
        )
        self.observedRejection = try container.decodeIfPresent(
            RouterScenarioRejectionKind.self,
            forKey: .observedRejection
        )
        self.observedDeferralID = try container.decodeIfPresent(
            RouterDeferralID.self,
            forKey: .observedDeferralID
        )
        self.expectation = try container.decodeIfPresent(
            RouterScenarioExpectation<R>.self,
            forKey: .expectation
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(submissionIndex, forKey: .submissionIndex)
        try container.encode(submissionEventIndex, forKey: .submissionEventIndex)
        try container.encode(terminalEventIndex, forKey: .terminalEventIndex)
        try container.encode(action, forKey: .action)
        try container.encode(context, forKey: .context)
        try container.encode(requestSemantics, forKey: .requestSemantics)
        try container.encode(expectedRevision, forKey: .expectedRevision)
        try container.encode(cancellationOrigin, forKey: .cancellationOrigin)
        try container.encode(observedState, forKey: .observedState)
        try container.encode(observedRevision, forKey: .observedRevision)
        try container.encode(observedTerminal, forKey: .observedTerminal)
        try container.encodeIfPresent(observedRejection, forKey: .observedRejection)
        try container.encodeIfPresent(observedDeferralID, forKey: .observedDeferralID)
        try container.encodeIfPresent(expectation, forKey: .expectation)
    }
}
