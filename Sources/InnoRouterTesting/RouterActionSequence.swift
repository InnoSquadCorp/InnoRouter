// MARK: - RouterActionSequence.swift
// InnoRouterTesting - deterministic action fixtures and production replay
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore
import InnoRouterSwiftUI

/// One production action together with the context observed by its policies.
public struct RouterActionStep<R: Route & Codable>: Codable, Sendable, Equatable {
    public let action: RouterAction<R>
    public let context: RouterTransitionContext

    public init(action: RouterAction<R>, context: RouterTransitionContext = .init()) {
        self.action = action
        self.context = context
    }
}

/// A versioned, deterministically encoded list of contextual router actions.
///
/// Sequences are fixtures for regression tests and bug reproduction. Replay
/// runs every action through ``RouterTestStore`` so reducers, policies, event
/// delivery, and rejection behavior remain identical to production.
/// The caller supplies the initial state, policies, and runtime dependencies.
/// Replay is sequential; it does not reproduce concurrent request timing.
/// Fixtures contain route payloads and request keys and are not redacted exports.
public struct RouterActionSequence<R: Route & Codable>: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let steps: [RouterActionStep<R>]
    public var actions: [RouterAction<R>] { steps.map(\.action) }

    public init(steps: [RouterActionStep<R>]) {
        self.schemaVersion = 1
        self.steps = steps
    }

    /// Creates a fixture whose actions all use the same context.
    public init(actions: [RouterAction<R>], context: RouterTransitionContext = .init()) {
        self.init(steps: actions.map { .init(action: $0, context: context) })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case steps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported router action sequence schema \(schemaVersion)."
            )
        }
        self.schemaVersion = schemaVersion
        self.steps = try container.decode(
            [RouterActionStep<R>].self,
            forKey: .steps
        )
    }

    /// Encodes the fixture using stable JSON key ordering.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a supported sequence schema.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Replays all actions in order through the production transition path.
    @MainActor
    @discardableResult
    public func replay(on store: RouterTestStore<R>) async -> [RouterOutcome<R>] {
        var outcomes: [RouterOutcome<R>] = []
        outcomes.reserveCapacity(steps.count)
        for step in steps {
            outcomes.append(await store.send(step.action, context: step.context))
        }
        return outcomes
    }
}
