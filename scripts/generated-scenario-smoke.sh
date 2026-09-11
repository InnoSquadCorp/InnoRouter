#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_DIR="$ROOT_DIR/.build/generated-scenario-smoke"

mkdir -p \
  "$SMOKE_DIR/Tests/FixtureGeneratorTests" \
  "$SMOKE_DIR/Tests/GeneratedScenarioTests"
rm -f \
  "$SMOKE_DIR/Package.swift" \
  "$SMOKE_DIR/Tests/FixtureGeneratorTests/FixtureGeneratorTests.swift" \
  "$SMOKE_DIR/Tests/GeneratedScenarioTests/Support.swift" \
  "$SMOKE_DIR/Tests/GeneratedScenarioTests/GeneratedScenarioTests.swift" \
  "$SMOKE_DIR/Tests/GeneratedScenarioTests/generated-scenario.json"

cat > "$SMOKE_DIR/Package.swift" <<EOF
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GeneratedScenarioSmoke",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$ROOT_DIR")],
    targets: [
        .testTarget(
            name: "FixtureGeneratorTests",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
                .product(name: "InnoRouterTesting", package: "InnoRouter"),
            ]
        ),
        .testTarget(
            name: "GeneratedScenarioTests",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
                .product(name: "InnoRouterTesting", package: "InnoRouter"),
            ],
            resources: [.copy("generated-scenario.json")]
        ),
    ]
)
EOF

cat > "$SMOKE_DIR/Tests/GeneratedScenarioTests/Support.swift" <<'EOF'
import Foundation
import SwiftUI
import InnoRouter
import InnoRouterTesting

enum ExternalScenarioRoute: String, Route, Codable {
    case home
    case detail
}

@Router
enum ExternalFeatureRoute: Codable {
    case home
    case detail

    var destination: some View { EmptyView() }
}

@Router
enum ExternalFeatureParentRoute: Codable {
    @FeatureRoute
    case feature(ExternalFeatureRoute)
    case replacement

    var destination: some View { EmptyView() }
}

@MainActor
func makeRouterTestStore(
    _ state: RouterState<ExternalScenarioRoute>
) -> RouterTestStore<ExternalScenarioRoute> {
    if ProcessInfo.processInfo.environment["SCENARIO_INITIAL_STATE_MISMATCH"] == "1" {
        return RouterTestStore(
            initialState: .rootStack(path: [.detail]),
            exhaustivity: .off
        )
    }
    let variant = ProcessInfo.processInfo.environment["SCENARIO_RUNTIME_VARIANT"] ?? "positive"
    if variant == "cancel-action" || variant == "cancel-history" {
        return RouterTestStore(
            initialState: state,
            configuration: .init(policies: [
                RouterPolicy(name: "approval") { transition in
                    let relevant = variant == "cancel-history"
                        ? transition.context.source == .history
                        : transition.action == .push(.detail)
                    return relevant && transition.context.resumedDeferral == nil
                        ? .deferRequest(RouterDeferralID())
                        : .allow
                },
                RouterPolicy(name: "resume-gate") { transition in
                    if transition.context.resumedDeferral != nil {
                        try? await Task.sleep(for: .seconds(30))
                    }
                    return .allow
                },
            ]),
            exhaustivity: .off
        )
    }
    return RouterTestStore(
        initialState: state,
        configuration: .init(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history
                    && transition.context.resumedDeferral == nil
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
        ]),
        exhaustivity: .off
    )
}

func makeRouterScenarioEnvironment() -> RouterScenarioReplayEnvironment {
    .init(routeSchemaID: String(describing: ExternalScenarioRoute.self))
}

@MainActor
func makeFeatureRouterTestStore(
    _ state: RouterState<ExternalFeatureParentRoute>
) -> RouterTestStore<ExternalFeatureParentRoute> {
    RouterTestStore(
        initialState: state,
        configuration: .init(policies: [
            RouterPolicy(name: "feature-approval") { transition in
                guard transition.context.resumedDeferral == nil,
                      case .apply = transition.action else { return .allow }
                return .deferRequest(RouterDeferralID())
            },
        ]),
        exhaustivity: .off
    )
}

func makeFeatureRouterScenarioEnvironment() -> RouterScenarioReplayEnvironment {
    .init(routeSchemaID: String(describing: ExternalFeatureParentRoute.self))
}

func makeFeatureResolvers() -> [RouterScenarioFeatureResolver<ExternalFeatureParentRoute>] {
    [.init(ExternalFeatureParentRoute.Feature.feature)]
}
EOF

touch "$SMOKE_DIR/Tests/GeneratedScenarioTests/generated-scenario.json"

cat > "$SMOKE_DIR/Tests/FixtureGeneratorTests/FixtureGeneratorTests.swift" <<'EOF'
import Foundation
import Testing
import SwiftUI

import InnoRouter
import InnoRouterTesting

enum ExternalScenarioRoute: String, Route, Codable {
    case home
    case detail
}

@Router
enum ExternalFeatureRoute: Codable {
    case home
    case detail

    var destination: some View { EmptyView() }
}

@Router
enum ExternalFeatureParentRoute: Codable {
    @FeatureRoute
    case feature(ExternalFeatureRoute)
    case replacement

    var destination: some View { EmptyView() }
}

@Suite("Fixture source generator")
struct FixtureGeneratorTests {
    @Test("Writes generated Swift Testing source")
    func fixtureGeneration() throws {
        let variant = ProcessInfo.processInfo.environment["SCENARIO_VARIANT"] ?? "positive"
        if variant == "feature-owner" {
            try generateFeatureOwnerFixture()
            return
        }
        if variant == "history" || variant == "history-preexisting" {
            try generateHistoryFixture(preexistingWindow: variant == "history-preexisting")
            return
        }
        if variant == "queued-history" {
            try generateQueuedHistoryFixture()
            return
        }
        if variant == "cancel-action" || variant == "cancel-history" {
            try generateCancellationFixture(history: variant == "cancel-history")
            return
        }
        let expectedState: RouterState<ExternalScenarioRoute> = variant == "state"
            ? .rootStack(path: [.detail])
            : .rootStack(path: [.home])
        let expectedRevision: UInt64 = variant == "revision" ? 2 : 1
        let expectedTerminal: RouterScenarioTerminal = variant == "terminal"
            ? .rejected
            : .applied
        let fixture = RouterScenarioFixture<ExternalScenarioRoute>(
            initialState: .rootStack,
            initialRevision: 0,
            steps: [
                .init(
                    submissionEventIndex: 0,
                    terminalEventIndex: 1,
                    action: .push(.home),
                    context: .init(source: .inspector),
                    observedState: .rootStack(path: [.home]),
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(
                        state: expectedState,
                        revision: expectedRevision,
                        terminal: expectedTerminal
                    )
                ),
            ]
        )
        let files = try RouterScenarioSourceGenerator.generateFiles(
            fixture,
            routeTypeName: "ExternalScenarioRoute",
            fixtureFileName: "generated-scenario.json",
            testName: "generatedScenario",
            storeFactory: "makeRouterTestStore",
            environmentFactory: "makeRouterScenarioEnvironment"
        )
        guard let sourceOutput = ProcessInfo.processInfo.environment["SCENARIO_SOURCE_OUTPUT"],
              let fixtureOutput = ProcessInfo.processInfo.environment["SCENARIO_FIXTURE_OUTPUT"] else {
            return
        }
        try Data(files.source.utf8).write(
            to: URL(fileURLWithPath: sourceOutput),
            options: .atomic
        )
        try files.fixtureData.write(
            to: URL(fileURLWithPath: fixtureOutput),
            options: .atomic
        )
    }

    private func generateFeatureOwnerFixture() throws {
        let deferralID = RouterDeferralID()
        let firstID = RouterTransitionID()
        let replacementID = RouterTransitionID()
        let resumeID = RouterTransitionID()
        let initial: RouterState<ExternalFeatureParentRoute> = .rootStack(
            path: [.feature(.home)]
        )
        let replacement: RouterState<ExternalFeatureParentRoute> = .rootStack(
            path: [.replacement]
        )
        let featureTarget = RouterNode<ExternalFeatureParentRoute>.stack(
            path: [.feature(.detail)]
        )
        let featureAction = RouterAction<ExternalFeatureParentRoute>.apply(
            .init(state: .rootStack(path: [.feature(.detail)]))
        )
        let entry = RouterFeatureCatalogEntry(
            id: ExternalFeatureParentRoute.Feature.feature.id,
            namespace: ExternalFeatureParentRoute.Feature.feature.namespace,
            childRouteTypeName: String(describing: ExternalFeatureRoute.self)
        )
        let semantics = RouterScenarioRequestSemantics<ExternalFeatureParentRoute>.featurePlan(
            scope: .root,
            lifetime: .application,
            node: featureTarget,
            features: [entry]
        )
        let fixture = RouterScenarioFixture<ExternalFeatureParentRoute>(
            initialState: initial,
            steps: [
                .init(
                    requestID: firstID,
                    submissionIndex: 0,
                    submissionEventIndex: 0,
                    terminalEventIndex: 1,
                    action: featureAction,
                    context: .init(),
                    requestSemantics: semantics,
                    observedState: initial,
                    observedRevision: 0,
                    observedTerminal: .deferred,
                    observedDeferralID: deferralID,
                    expectation: .init(state: initial, revision: 0, terminal: .deferred)
                ),
                .init(
                    requestID: replacementID,
                    submissionIndex: 1,
                    submissionEventIndex: 2,
                    terminalEventIndex: 3,
                    action: .replaceStack([.replacement]),
                    context: .init(),
                    observedState: replacement,
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(state: replacement, revision: 1, terminal: .applied)
                ),
                .init(
                    requestID: resumeID,
                    submissionIndex: 2,
                    submissionEventIndex: 5,
                    terminalEventIndex: 6,
                    action: featureAction,
                    context: .init(resumedDeferral: deferralID),
                    requestSemantics: semantics,
                    observedState: replacement,
                    observedRevision: 1,
                    observedTerminal: .rejected,
                    observedRejection: .featureProjection,
                    expectation: .init(
                        state: replacement,
                        revision: 1,
                        terminal: .rejected,
                        rejection: .featureProjection
                    )
                ),
            ],
            controls: [
                .submit(requestID: firstID, eventIndex: 0),
                .awaitTerminal(requestID: firstID, eventIndex: 1),
                .submit(requestID: replacementID, eventIndex: 2),
                .awaitTerminal(requestID: replacementID, eventIndex: 3),
                .resolveDeferral(
                    requestID: resumeID,
                    deferralID: deferralID,
                    resolution: .allow,
                    resumeStrategy: .rebaseOnCurrentState,
                    eventIndex: 4
                ),
                .awaitTerminal(requestID: resumeID, eventIndex: 6),
            ]
        )
        let files = try RouterScenarioSourceGenerator.generateFiles(
            fixture,
            routeTypeName: "ExternalFeatureParentRoute",
            fixtureFileName: "generated-scenario.json",
            testName: "generatedScenario",
            storeFactory: "makeFeatureRouterTestStore",
            environmentFactory: "makeFeatureRouterScenarioEnvironment",
            featureResolversFactory: "makeFeatureResolvers"
        )
        guard let sourceOutput = ProcessInfo.processInfo.environment["SCENARIO_SOURCE_OUTPUT"],
              let fixtureOutput = ProcessInfo.processInfo.environment["SCENARIO_FIXTURE_OUTPUT"] else {
            return
        }
        try Data(files.source.utf8).write(
            to: URL(fileURLWithPath: sourceOutput), options: .atomic
        )
        try files.fixtureData.write(
            to: URL(fileURLWithPath: fixtureOutput), options: .atomic
        )
    }

    @Test("Rejects malformed resume graphs before generating source")
    func rejectsMalformedResumeGraph() {
        let deferralID = RouterDeferralID()
        let producerID = RouterTransitionID()
        let resumedID = RouterTransitionID()
        let fixture = RouterScenarioFixture<ExternalScenarioRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: producerID,
                    submissionIndex: 0,
                    submissionEventIndex: 0,
                    terminalEventIndex: 1,
                    action: .push(.detail),
                    context: .init(),
                    observedState: .rootStack,
                    observedRevision: 0,
                    observedTerminal: .deferred,
                    observedDeferralID: deferralID,
                    expectation: .init(state: .rootStack, revision: 0, terminal: .deferred)
                ),
                .init(
                    requestID: resumedID,
                    submissionIndex: 1,
                    submissionEventIndex: -1,
                    terminalEventIndex: 3,
                    action: .push(.home),
                    context: .init(),
                    observedState: .rootStack(path: [.detail]),
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(
                        state: .rootStack(path: [.detail]),
                        revision: 1,
                        terminal: .applied
                    )
                ),
            ],
            controls: [
                .submit(requestID: producerID, eventIndex: 0),
                .awaitTerminal(requestID: producerID, eventIndex: 1),
                .resolveDeferral(
                    requestID: resumedID,
                    deferralID: deferralID,
                    resolution: .allow,
                    resumeStrategy: .rebaseOnCurrentState,
                    eventIndex: 2
                ),
                .awaitTerminal(requestID: resumedID, eventIndex: 3),
            ]
        )
        #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "ExternalScenarioRoute"
            )
        }
    }

    @Test("Rejects tampered history resume actions before generating source")
    func rejectsTamperedHistoryResumeAction() {
        let deferralID = RouterDeferralID()
        let target = RouterState<ExternalScenarioRoute>.rootStack(path: [.home])
        var resumedContext = RouterTransitionContext(source: .history)
        resumedContext.resumedDeferral = deferralID
        let steps: [RouterScenarioStep<ExternalScenarioRoute>] = [
            .init(
                submissionIndex: 0,
                submissionEventIndex: 0,
                terminalEventIndex: 1,
                action: .apply(.init(state: target)),
                context: .init(source: .history),
                requestSemantics: .historyNavigation(target),
                expectedRevision: 0,
                observedState: .rootStack(path: [.home, .detail]),
                observedRevision: 0,
                observedTerminal: .deferred,
                observedDeferralID: deferralID,
                expectation: .init(
                    state: .rootStack(path: [.home, .detail]),
                    revision: 0,
                    terminal: .deferred
                )
            ),
            .init(
                submissionIndex: 1,
                submissionEventIndex: 3,
                terminalEventIndex: 4,
                action: .apply(.init(state: .rootStack(path: [.detail]))),
                context: resumedContext,
                requestSemantics: .historyNavigation(target),
                observedState: target,
                observedRevision: 1,
                observedTerminal: .applied,
                expectation: .init(state: target, revision: 1, terminal: .applied)
            ),
        ]
        let fixture = RouterScenarioFixture<ExternalScenarioRoute>(
            initialState: .rootStack(path: [.home, .detail]),
            steps: steps,
            controls: [
                .submit(requestID: steps[0].requestID, eventIndex: 0),
                .awaitTerminal(requestID: steps[0].requestID, eventIndex: 1),
                .resolveDeferral(
                    requestID: steps[1].requestID,
                    deferralID: deferralID,
                    resolution: .allow,
                    resumeStrategy: .rebaseOnCurrentState,
                    eventIndex: 2
                ),
                .awaitTerminal(requestID: steps[1].requestID, eventIndex: 4),
            ]
        )

        #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "ExternalScenarioRoute"
            )
        }
    }

    private func generateQueuedHistoryFixture() throws {
        let target = RouterState<ExternalScenarioRoute>.rootStack
        let steps: [RouterScenarioStep<ExternalScenarioRoute>] = [
            .init(
                submissionIndex: 0,
                submissionEventIndex: 0,
                terminalEventIndex: 1,
                action: .push(.home),
                context: .init(),
                observedState: .rootStack(path: [.home]),
                observedRevision: 1,
                observedTerminal: .applied,
                expectation: .init(
                    state: .rootStack(path: [.home]), revision: 1, terminal: .applied
                )
            ),
            .init(
                submissionIndex: 1,
                submissionEventIndex: 2,
                terminalEventIndex: 3,
                action: .push(.detail),
                context: .init(),
                observedState: .rootStack(path: [.home, .detail]),
                observedRevision: 2,
                observedTerminal: .applied,
                expectation: .init(
                    state: .rootStack(path: [.home, .detail]),
                    revision: 2,
                    terminal: .applied
                )
            ),
            .init(
                submissionIndex: 2,
                submissionEventIndex: 4,
                terminalEventIndex: 5,
                action: .apply(.init(state: target)),
                context: .init(source: .history),
                requestSemantics: .historyNavigation(target),
                expectedRevision: 1,
                observedState: .rootStack(path: [.home, .detail]),
                observedRevision: 2,
                observedTerminal: .rejected,
                observedRejection: .staleState,
                expectation: .init(
                    state: .rootStack(path: [.home, .detail]),
                    revision: 2,
                    terminal: .rejected,
                    rejection: .staleState
                )
            ),
        ]
        let fixture = RouterScenarioFixture<ExternalScenarioRoute>(
            initialState: .rootStack,
            steps: steps,
            controls: [
                .submit(requestID: steps[0].requestID, eventIndex: 0),
                .awaitTerminal(requestID: steps[0].requestID, eventIndex: 1),
                .submit(requestID: steps[1].requestID, eventIndex: 2),
                .awaitTerminal(requestID: steps[1].requestID, eventIndex: 3),
                .submit(requestID: steps[2].requestID, eventIndex: 4),
                .awaitTerminal(requestID: steps[2].requestID, eventIndex: 5),
            ]
        )
        try writeGeneratedFiles(fixture)
    }

    private func generateCancellationFixture(history: Bool) throws {
        let deferralID = RouterDeferralID()
        let target = RouterState<ExternalScenarioRoute>.rootStack(path: [.home])
        var resumedContext = RouterTransitionContext(source: history ? .history : .application)
        resumedContext.resumedDeferral = deferralID
        let action: RouterAction<ExternalScenarioRoute> = history
            ? .apply(.init(state: target))
            : .push(.detail)
        let semantics: RouterScenarioRequestSemantics<ExternalScenarioRoute> = history
            ? .historyNavigation(target)
            : .action
        let initialState: RouterState<ExternalScenarioRoute> = history
            ? .rootStack(path: [.home, .detail])
            : .rootStack
        let steps: [RouterScenarioStep<ExternalScenarioRoute>] = [
            .init(
                submissionIndex: 0,
                submissionEventIndex: 0,
                terminalEventIndex: 2,
                action: action,
                context: .init(source: history ? .history : .application),
                requestSemantics: semantics,
                expectedRevision: history ? 0 : nil,
                observedState: initialState,
                observedRevision: 0,
                observedTerminal: .deferred,
                observedDeferralID: deferralID,
                expectation: .init(state: initialState, revision: 0, terminal: .deferred)
            ),
            .init(
                submissionIndex: 1,
                submissionEventIndex: 4,
                terminalEventIndex: 7,
                action: action,
                context: resumedContext,
                requestSemantics: semantics,
                cancellationOrigin: .request,
                observedState: initialState,
                observedRevision: 0,
                observedTerminal: .rejected,
                observedRejection: .cancelled,
                expectation: .init(
                    state: initialState,
                    revision: 0,
                    terminal: .rejected,
                    rejection: .cancelled
                )
            ),
        ]
        let fixture = RouterScenarioFixture<ExternalScenarioRoute>(
            initialState: initialState,
            steps: steps,
            controls: [
                .submit(requestID: steps[0].requestID, eventIndex: 0),
                .waitUntilStarted(requestID: steps[0].requestID, eventIndex: 1),
                .awaitTerminal(requestID: steps[0].requestID, eventIndex: 2),
                .resolveDeferral(
                    requestID: steps[1].requestID,
                    deferralID: deferralID,
                    resolution: .allow,
                    resumeStrategy: .rebaseOnCurrentState,
                    eventIndex: 3
                ),
                .waitUntilStarted(requestID: steps[1].requestID, eventIndex: 5),
                .cancel(requestID: steps[1].requestID, eventIndex: 6),
                .awaitTerminal(requestID: steps[1].requestID, eventIndex: 7),
            ]
        )
        try writeGeneratedFiles(fixture)
    }

    private func writeGeneratedFiles(
        _ fixture: RouterScenarioFixture<ExternalScenarioRoute>
    ) throws {
        let files = try RouterScenarioSourceGenerator.generateFiles(
            fixture,
            routeTypeName: "ExternalScenarioRoute",
            fixtureFileName: "generated-scenario.json",
            testName: "generatedScenario",
            storeFactory: "makeRouterTestStore",
            environmentFactory: "makeRouterScenarioEnvironment"
        )
        guard let sourceOutput = ProcessInfo.processInfo.environment["SCENARIO_SOURCE_OUTPUT"],
              let fixtureOutput = ProcessInfo.processInfo.environment["SCENARIO_FIXTURE_OUTPUT"] else {
            return
        }
        try Data(files.source.utf8).write(
            to: URL(fileURLWithPath: sourceOutput), options: .atomic
        )
        try files.fixtureData.write(
            to: URL(fileURLWithPath: fixtureOutput), options: .atomic
        )
    }

    private func generateHistoryFixture(preexistingWindow: Bool) throws {
        let deferralID = RouterDeferralID()
        let windowID = UUID()
        let target = RouterState<ExternalScenarioRoute>.rootStack(path: [.home])
        let window = RouterWindow<ExternalScenarioRoute>(id: windowID, route: .detail)
        let stateWithWindow = try RouterState(
            root: .stack(path: [.home, .detail]),
            windows: [window]
        )
        let finalState = try RouterState(
            root: .stack(path: [.home]),
            windows: [window]
        )
        let ordinarySteps: [RouterScenarioStep<ExternalScenarioRoute>] = [
            .init(
                submissionIndex: 0,
                submissionEventIndex: 0,
                terminalEventIndex: 1,
                action: .push(.home),
                context: .init(source: .inspector),
                observedState: .rootStack(path: [.home]),
                observedRevision: 1,
                observedTerminal: .applied,
                expectation: .init(
                    state: .rootStack(path: [.home]), revision: 1, terminal: .applied
                )
            ),
            .init(
                submissionIndex: 1,
                submissionEventIndex: 2,
                terminalEventIndex: 3,
                action: .push(.detail),
                context: .init(source: .inspector),
                observedState: .rootStack(path: [.home, .detail]),
                observedRevision: 2,
                observedTerminal: .applied,
                expectation: .init(
                    state: .rootStack(path: [.home, .detail]), revision: 2, terminal: .applied
                )
            ),
        ]
        let historySteps: [RouterScenarioStep<ExternalScenarioRoute>] = preexistingWindow
            ? [
                .init(
                    submissionIndex: 2,
                    submissionEventIndex: 4,
                    terminalEventIndex: 5,
                    action: .openWindow(window),
                    context: .init(source: .inspector),
                    observedState: stateWithWindow,
                    observedRevision: 3,
                    observedTerminal: .applied,
                    expectation: .init(state: stateWithWindow, revision: 3, terminal: .applied)
                ),
                .init(
                    submissionIndex: 3,
                    submissionEventIndex: 6,
                    terminalEventIndex: 7,
                    action: .apply(.init(state: finalState)),
                    context: .init(source: .history),
                    requestSemantics: .historyNavigation(target),
                    expectedRevision: 3,
                    observedState: stateWithWindow,
                    observedRevision: 3,
                    observedTerminal: .deferred,
                    observedDeferralID: deferralID,
                    expectation: .init(state: stateWithWindow, revision: 3, terminal: .deferred)
                ),
                .init(
                    submissionIndex: 4,
                    submissionEventIndex: 9,
                    terminalEventIndex: 10,
                    action: .apply(.init(state: finalState)),
                    context: .init(source: .history, resumedDeferral: deferralID),
                    requestSemantics: .historyNavigation(target),
                    observedState: finalState,
                    observedRevision: 4,
                    observedTerminal: .applied,
                    expectation: .init(state: finalState, revision: 4, terminal: .applied)
                ),
            ]
            : [
            .init(
                submissionIndex: 2,
                submissionEventIndex: 4,
                terminalEventIndex: 5,
                action: .apply(.init(state: target)),
                context: .init(source: .history),
                expectedRevision: 2,
                observedState: .rootStack(path: [.home, .detail]),
                observedRevision: 2,
                observedTerminal: .deferred,
                observedDeferralID: deferralID,
                expectation: .init(
                    state: .rootStack(path: [.home, .detail]), revision: 2, terminal: .deferred
                )
            ),
            .init(
                submissionIndex: 3,
                submissionEventIndex: 6,
                terminalEventIndex: 7,
                action: .openWindow(window),
                context: .init(source: .inspector),
                observedState: stateWithWindow,
                observedRevision: 3,
                observedTerminal: .applied,
                expectation: .init(state: stateWithWindow, revision: 3, terminal: .applied)
            ),
            .init(
                submissionIndex: 4,
                submissionEventIndex: 9,
                terminalEventIndex: 10,
                action: .apply(.init(state: target)),
                context: .init(source: .history, resumedDeferral: deferralID),
                observedState: finalState,
                observedRevision: 4,
                observedTerminal: .applied,
                expectation: .init(state: finalState, revision: 4, terminal: .applied)
            ),
        ]
        let steps = ordinarySteps + historySteps
        let fixture = RouterScenarioFixture<ExternalScenarioRoute>(
            initialState: .rootStack,
            steps: steps,
            controls: [
                .submit(requestID: steps[0].requestID, eventIndex: 0),
                .awaitTerminal(requestID: steps[0].requestID, eventIndex: 1),
                .submit(requestID: steps[1].requestID, eventIndex: 2),
                .awaitTerminal(requestID: steps[1].requestID, eventIndex: 3),
                .submit(requestID: steps[2].requestID, eventIndex: 4),
                .awaitTerminal(requestID: steps[2].requestID, eventIndex: 5),
                .submit(requestID: steps[3].requestID, eventIndex: 6),
                .awaitTerminal(requestID: steps[3].requestID, eventIndex: 7),
                .resolveDeferral(
                    requestID: steps[4].requestID,
                    deferralID: deferralID,
                    resolution: .allow,
                    resumeStrategy: .rebaseOnCurrentState,
                    eventIndex: 8
                ),
                .awaitTerminal(requestID: steps[4].requestID, eventIndex: 10),
            ]
        )
        let files = try RouterScenarioSourceGenerator.generateFiles(
            fixture,
            routeTypeName: "ExternalScenarioRoute",
            fixtureFileName: "generated-scenario.json",
            testName: "generatedScenario",
            storeFactory: "makeRouterTestStore",
            environmentFactory: "makeRouterScenarioEnvironment"
        )
        guard let sourceOutput = ProcessInfo.processInfo.environment["SCENARIO_SOURCE_OUTPUT"],
              let fixtureOutput = ProcessInfo.processInfo.environment["SCENARIO_FIXTURE_OUTPUT"] else {
            return
        }
        try Data(files.source.utf8).write(
            to: URL(fileURLWithPath: sourceOutput), options: .atomic
        )
        try files.fixtureData.write(
            to: URL(fileURLWithPath: fixtureOutput), options: .atomic
        )
    }
}
EOF

generate() {
  local variant="$1"
  SCENARIO_VARIANT="$variant" \
  SCENARIO_SOURCE_OUTPUT="$SMOKE_DIR/Tests/GeneratedScenarioTests/GeneratedScenarioTests.swift" \
  SCENARIO_FIXTURE_OUTPUT="$SMOKE_DIR/Tests/GeneratedScenarioTests/generated-scenario.json" \
    swift test --package-path "$SMOKE_DIR" --jobs 2 --filter FixtureGeneratorTests.fixtureGeneration
}

run_generated() {
  local variant="$1"
  SCENARIO_RUNTIME_VARIANT="$variant" \
    swift test --package-path "$SMOKE_DIR" --jobs 2
}

generate positive
run_generated positive
generate history
run_generated history
generate history-preexisting
run_generated history-preexisting
generate queued-history
run_generated queued-history
generate cancel-action
run_generated cancel-action
generate cancel-history
run_generated cancel-history
generate feature-owner
run_generated feature-owner

for variant in state revision terminal; do
  generate "$variant"
  log="$SMOKE_DIR/$variant-negative.log"
  if swift test --package-path "$SMOKE_DIR" --jobs 2 >"$log" 2>&1; then
    echo "[generated-scenario-smoke] Failed: $variant mismatch unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -q "${variant}Mismatch" "$log"; then
    echo "[generated-scenario-smoke] Failed: $variant mismatch did not reach replay assertion" >&2
    cat "$log" >&2
    exit 1
  fi
done

initial_state_log="$SMOKE_DIR/initial-state-negative.log"
generate positive
if SCENARIO_INITIAL_STATE_MISMATCH=1 \
  swift test --package-path "$SMOKE_DIR" --jobs 2 >"$initial_state_log" 2>&1; then
  echo "[generated-scenario-smoke] Failed: initial state mismatch unexpectedly passed" >&2
  exit 1
fi
if ! grep -q "initialStateMismatch" "$initial_state_log"; then
  echo "[generated-scenario-smoke] Failed: initial state mismatch did not reach replay preflight" >&2
  cat "$initial_state_log" >&2
  exit 1
fi

echo "[generated-scenario-smoke] Generated source and format-7 fixture compiled and ran, including stale history, action/history resume cancellation, history rebase, and macro-generated feature ownership rejection; malformed generation and initial state/state/revision/terminal negatives failed as expected"
