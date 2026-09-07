import Foundation
import Testing

import InnoRouter
import InnoRouterInspector
import InnoRouterTesting

private enum CapturedRoute: String, Route, Codable {
    case home
    case detail
    case window
}

private enum ScenarioControllerFailure: Error {
    case expected
}

@MainActor
private final class ScenarioCancellationProbe {
    var entered = false
    var cancelled = false

    func wait() async -> RouterPolicyDecision {
        entered = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelled = true
        }
        return .allow
    }
}

@MainActor
private final class ScenarioGate {
    private var entered = false
    private var released = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

@MainActor
private final class ImmediateCancellationTaskBox {
    var task: Task<RouterOutcome<CapturedRoute>, Never>?
}

@Suite("Router scenario capture")
@MainActor
struct RouterScenarioCaptureTests {
    @Test(
        "Immediate Task cancellation records provenance before the terminal",
        arguments: [false, true],
        [false, true]
    )
    func immediateTaskCancellationRecordsProvenance(
        atPolicyPrepared: Bool,
        resumingDeferral: Bool
    ) async throws {
        let taskBox = ImmediateCancellationTaskBox()
        let configuration = RouterStoreConfiguration<CapturedRoute>(
            policies: [
                RouterPolicy(name: "approval") { transition in
                    resumingDeferral && transition.context.resumedDeferral == nil
                        ? .deferRequest(RouterDeferralID())
                        : .allow
                },
                RouterPolicy(name: "allow") { _ in .allow },
            ],
            onEvent: { event in
                guard let task = taskBox.task else { return }
                switch event {
                case .started where !atPolicyPrepared:
                    task.cancel()
                case .policyPrepared where atPolicyPrepared:
                    task.cancel()
                default:
                    break
                }
            }
        )
        let store = RouterStore<CapturedRoute>(configuration: configuration)
        let recorder = RouterScenarioRecorder(store: store)

        if resumingDeferral {
            guard case .deferred(_, _, _, let deferral) = await store.perform(.push(.home)) else {
                Issue.record("Expected an initial deferred request")
                return
            }
            taskBox.task = Task { @MainActor in
                await recorder.resolveDeferred(
                    deferral.id,
                    with: .allow,
                    resumeStrategy: .rebaseOnCurrentState
                )
            }
        } else {
            taskBox.task = store.dispatch(.push(.home))
        }

        guard case .rejected(_, _, 0, .cancelled) = await taskBox.task?.value else {
            Issue.record("Expected immediate cancellation before commit")
            return
        }
        let captured = recorder.stop()
        let cancelledStep = try #require(captured.steps.last)
        #expect(cancelledStep.cancellationOrigin == .request)
        #expect(captured.controls.filter { control in
            if case .cancel(let requestID, _) = control {
                return requestID == cancelledStep.requestID
            }
            return false
        }.count == 1)
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        #expect(fixture.completeness.isComplete)
        _ = try RouterScenarioSourceGenerator.generate(
            fixture,
            routeTypeName: "CapturedRoute"
        )
        #expect(store.revision == 0)
        taskBox.task = nil
    }

    @Test("Inspector scenario controller exposes failure, cancellation, and import boundaries")
    func inspectorScenarioControllerBoundaries() {
        let startFailure = RouterInspectorScenarioController(
            capacity: 0,
            start: { throw ScenarioControllerFailure.expected },
            stop: { throw ScenarioControllerFailure.expected },
            currentStepCount: { 0 }
        )
        #expect(startFailure.capacity == 1)
        #expect(!startFailure.canImportRawFixture)
        startFailure.start()
        #expect(startFailure.status == .failed)
        #expect(startFailure.failure == .startFailed)
        #expect(!startFailure.summary.contains("expected"))

        let stopFailure = RouterInspectorScenarioController(
            capacity: 2,
            start: {},
            stop: { throw ScenarioControllerFailure.expected },
            currentStepCount: { 4 }
        )
        stopFailure.start()
        stopFailure.refreshProgress()
        #expect(stopFailure.capturedStepCount == 2)
        stopFailure.stop()
        #expect(stopFailure.status == .failed)
        #expect(stopFailure.failure == .stopFailed)

        var cancellationStops = 0
        let cancellable = RouterInspectorScenarioController(
            capacity: 2,
            start: {},
            stop: {
                cancellationStops += 1
                return .init(status: .complete, capturedStepCount: 1, summary: "stopped")
            },
            currentStepCount: { 0 }
        )
        cancellable.start()
        cancellable.cancel()
        #expect(cancellationStops == 1)
        #expect(cancellable.status == .cancelled)
        #expect(cancellable.rawExportData() == nil)

        let importFailure = RouterInspectorScenarioController(
            capacity: 2,
            start: {},
            stop: { .init(status: .complete, capturedStepCount: 0, summary: "") },
            currentStepCount: { 0 },
            importFixture: { _ in throw ScenarioControllerFailure.expected }
        )
        #expect(importFailure.canImportRawFixture)
        importFailure.importRawFixture(Data("invalid".utf8))
        #expect(importFailure.status == .failed)
        #expect(importFailure.failure == .importFailed)
        #expect(!importFailure.summary.contains("expected"))
        #expect(importFailure.rawExportData() == nil)
    }

    @Test("Inspector scenario controls require explicit start, stop, and raw export")
    func inspectorScenarioAdapterFlow() async throws {
        let store = RouterStore<CapturedRoute>()
        let controller = RouterInspectorScenarioController.routerScenario(
            store: store,
            capacity: 4
        )
        #expect(controller.status == .idle)

        controller.start()
        _ = await store.perform(.push(.detail))
        controller.refreshProgress()
        #expect(controller.status == .recording)
        #expect(controller.capturedStepCount == 1)

        controller.stop()
        #expect(controller.status == .incomplete)
        #expect(controller.summary.contains("missingExpectations=1"))
        let data = try #require(controller.rawExportData())
        let fixture = try RouterScenarioFixture<CapturedRoute>.decode(from: data)
        #expect(fixture.steps.count == 1)

        let imported = RouterInspectorScenarioController.routerScenario(store: store)
        imported.importRawFixture(data)
        #expect(imported.status == .incomplete)
        #expect(imported.capturedStepCount == 1)

        let sentinel = "PRIVATE_ROUTE_TOKEN_123"
        let invalid = try #require(
            String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\"detail\"", with: "\"\(sentinel)\"")
                .data(using: .utf8)
        )
        imported.importRawFixture(invalid)
        #expect(imported.status == .failed)
        #expect(imported.failure == .importFailed)
        #expect(!imported.summary.contains(sentinel))
        #expect(imported.rawExportData() == nil)
    }

    @Test("Inspector capture exports, replays with fresh IDs, and checkpoints the result")
    func inspectorCaptureReplayCheckpointIntegration() async throws {
        let source = RouterStore<CapturedRoute>()
        let controller = RouterInspectorScenarioController.routerScenario(store: source)
        controller.start()
        _ = await source.perform(.push(.detail))
        controller.stop()
        let raw = try #require(controller.rawExportData())
        let captured = try RouterScenarioFixture<CapturedRoute>.decode(from: raw)
        let sourceRequestID = try #require(captured.steps.first?.requestID)
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let runtime = RouterTestRuntime(transitionIDSeed: 99)
        let target = RouterTestStore<CapturedRoute>(
            exhaustivity: .off,
            runtime: runtime
        )
        let history = RouterHistory(store: target.store)

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.first?.id != sourceRequestID)
        #expect(target.state == .rootStack(path: [.detail]))
        guard case .success(let checkpoint) = history.createCheckpoint(named: "replayed") else {
            Issue.record("Expected replay checkpoint")
            return
        }
        #expect(checkpoint.entry.navigationState == target.state)
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("Cancelled capture waiters and stopped recorders complete")
    func cancelledCaptureWaitersComplete() async {
        let store = RouterStore<CapturedRoute>()
        let recorder = RouterScenarioRecorder(store: store)
        let captured = Task { @MainActor in await recorder.waitUntilCaptured(1) }
        let observed = Task { @MainActor in await recorder.waitUntilObserved(1) }

        captured.cancel()
        observed.cancel()

        #expect(await captured.value == false)
        #expect(await observed.value == false)
        let fixture = recorder.stop()
        #expect(fixture.steps.isEmpty)
    }

    @Test("Stopped capture rejects controls and remains immutable")
    func stoppedCaptureDoesNotAcceptNewControls() async {
        let store = RouterStore<CapturedRoute>()
        let recorder = RouterScenarioRecorder(store: store)
        let clock = RouterTestClock()
        let first = recorder.stop()

        recorder.advanceTime(byNanoseconds: 10, on: clock)
        let outcome = await recorder.resolveDeferred(RouterDeferralID(), with: .allow)
        let second = recorder.stop()

        #expect(first == second)
        #expect(clock.now == Date(timeIntervalSince1970: 0))
        #expect(store.revision == 0)
        guard case .rejected(_, _, _, .cancelled) = outcome else {
            Issue.record("Expected stopped capture to reject the control locally")
            return
        }
    }

    @Test("Explicit capture pairs every submitted request with its terminal state")
    func completeCaptureAndSourceGeneration() async throws {
        let store = RouterStore<CapturedRoute>()
        let recorder = RouterScenarioRecorder(store: store)

        _ = await store.perform(.push(.home))
        _ = await store.perform(.pushIfNeeded(.home))
        _ = await store.perform(.pop(count: 2))
        #expect(await recorder.waitUntilCaptured(3))

        let captured = recorder.stop()
        #expect(!captured.completeness.isComplete)
        #expect(captured.completeness.missingExpectationCount == 3)
        #expect(captured.steps.map(\.observedTerminal) == [.applied, .unchanged, .rejected])
        #expect(captured.steps.map(\.observedRevision) == [1, 1, 1])
        #expect(captured.steps.last?.observedState.root == .stack(path: [.home]))

        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal
            )
        })
        #expect(fixture.completeness.isComplete)

        let encoded = try JSONEncoder().encode(fixture)
        #expect(try JSONDecoder().decode(
            RouterScenarioFixture<CapturedRoute>.self,
            from: encoded
        ) == fixture)
        #expect(throws: RouterScenarioFixtureError.encodedDataTooLarge(
            actual: encoded.count,
            maximum: 1
        )) {
            _ = try RouterScenarioFixture<CapturedRoute>.decode(
                from: encoded,
                maximumByteCount: 1
            )
        }
        #expect(throws: RouterScenarioFixtureError.tooManySteps(actual: 3, maximum: 2)) {
            _ = try RouterScenarioFixture<CapturedRoute>.decode(
                from: encoded,
                maximumStepCount: 2
            )
        }

        let futureFormat = try #require(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "\"formatVersion\":5",
                with: "\"formatVersion\":6"
            ).data(using: .utf8)
        )
        #expect(throws: RouterScenarioFixtureError.unsupportedFormatVersion(6)) {
            _ = try RouterScenarioFixture<CapturedRoute>.decode(from: futureFormat)
        }
        let legacyFormat = try #require(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "\"formatVersion\":5",
                with: "\"formatVersion\":4"
            ).data(using: .utf8)
        )
        #expect(throws: RouterScenarioFixtureError.unsupportedFormatVersion(4)) {
            _ = try RouterScenarioFixture<CapturedRoute>.decode(from: legacyFormat)
        }
        var missingSemanticsObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var missingSemanticsSteps = try #require(
            missingSemanticsObject["steps"] as? [[String: Any]]
        )
        missingSemanticsSteps[0].removeValue(forKey: "requestSemantics")
        missingSemanticsObject["steps"] = missingSemanticsSteps
        let missingSemantics = try JSONSerialization.data(withJSONObject: missingSemanticsObject)
        #expect(throws: DecodingError.self) {
            _ = try RouterScenarioFixture<CapturedRoute>.decode(from: missingSemantics)
        }
        for requiredKey in ["expectedRevision", "cancellationOrigin"] {
            var missingFieldObject = try #require(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            var missingFieldSteps = try #require(
                missingFieldObject["steps"] as? [[String: Any]]
            )
            missingFieldSteps[0].removeValue(forKey: requiredKey)
            missingFieldObject["steps"] = missingFieldSteps
            let missingField = try JSONSerialization.data(withJSONObject: missingFieldObject)
            #expect(throws: DecodingError.self) {
                _ = try RouterScenarioFixture<CapturedRoute>.decode(from: missingField)
            }
        }

        let source = try RouterScenarioSourceGenerator.generate(
            fixture,
            routeTypeName: "CapturedRoute",
            testName: "capturedNavigation",
            storeFactory: "makeRouterTestStore"
        )
        #expect(source.contains("@Test(\"Captured InnoRouter scenario\")"))
        #expect(source.contains("RouterScenarioFixture<CapturedRoute>"))
        #expect(source.contains("RouterScenarioRunner.replay(fixture, on: store)"))

        let files = try RouterScenarioSourceGenerator.generateFiles(
            fixture,
            routeTypeName: "CapturedRoute",
            fixtureFileName: "captured-navigation.json",
            testName: "capturedNavigation",
            storeFactory: "makeRouterTestStore",
            environmentFactory: "makeRouterScenarioEnvironment"
        )
        #expect(files.fixtureFileName == "captured-navigation.json")
        #expect(files.source.contains("Data(contentsOf: fixtureURL)"))
        #expect(files.source.contains("makeRouterScenarioEnvironment()"))
        #expect(try RouterScenarioFixture<CapturedRoute>.decode(from: files.fixtureData) == fixture)
    }

    @Test("Stopping immediately after a completed request cannot lose the pair")
    func immediateStopIncludesCompletedRequest() async {
        for _ in 0..<100 {
            let store = RouterStore<CapturedRoute>()
            let recorder = RouterScenarioRecorder(store: store)

            _ = await store.perform(.push(.home))
            let fixture = recorder.stop()

            #expect(fixture.steps.count == 1)
            #expect(fixture.completeness.unpairedRequestCount == 0)
            #expect(fixture.initialRevision == 0)
        }
    }

    @Test("Replay preserves overlapping busy rejection and relative revisions")
    func replayPreservesConcurrencyAndRevisionBaseline() async throws {
        let context = RouterTransitionContext(source: .inspector)
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            initialRevision: 7,
            steps: [
                .init(
                    submissionIndex: 0,
                    submissionEventIndex: 0,
                    terminalEventIndex: 3,
                    action: .push(.home),
                    context: context,
                    observedState: .rootStack(path: [.home]),
                    observedRevision: 8,
                    observedTerminal: .applied,
                    expectation: .init(
                        state: .rootStack(path: [.home]),
                        revision: 8,
                        terminal: .applied
                    )
                ),
                .init(
                    submissionIndex: 1,
                    submissionEventIndex: 1,
                    terminalEventIndex: 2,
                    action: .push(.detail),
                    context: context,
                    observedState: .rootStack,
                    observedRevision: 7,
                    observedTerminal: .rejected,
                    expectation: .init(
                        state: .rootStack,
                        revision: 7,
                        terminal: .rejected
                    )
                ),
            ]
        )
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(
                policies: [RouterPolicy(name: "gate") { transition in
                    guard transition.context.source == .inspector else { return .allow }
                    for await _ in gate { break }
                    return .allow
                }],
                schedulingPolicy: .rejectWhileBusy
            ),
            exhaustivity: .off
        )
        _ = await store.send(.push(.home))
        _ = await store.send(.pop(count: 1))
        #expect(store.revision == 2)

        let replay = Task { @MainActor in
            try await RouterScenarioRunner.replay(fixture, on: store)
        }
        let rejected = await store.waitForEvent { event in
            guard case .rejected(_, _, _, .busy, _) = event else { return false }
            return true
        }
        #expect(rejected != nil)
        continuation.yield()
        continuation.finish()

        let outcomes = try await replay.value
        #expect(outcomes.map(RouterScenarioTerminal.init) == [.applied, .rejected])
        #expect(store.revision == 3)
        #expect(store.state.root == .stack(path: [.home]))
        await store.finish()
    }

    @Test("Replay executes explicit cancellation and virtual-time controls")
    func explicitCancellationAndTimeControls() async throws {
        let cancellationID = RouterTransitionID(
            rawValue: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        )
        let timeoutID = RouterTransitionID(
            rawValue: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
        )
        let cancelled = RouterScenarioStep<CapturedRoute>(
            requestID: cancellationID,
            submissionEventIndex: 0,
            terminalEventIndex: 3,
            action: .push(.home),
            context: .init(),
            cancellationOrigin: .request,
            observedState: .rootStack,
            observedRevision: 0,
            observedTerminal: .rejected,
            observedRejection: .cancelled,
            expectation: .init(
                state: .rootStack,
                revision: 0,
                terminal: .rejected,
                rejection: .cancelled
            )
        )
        let timedOut = RouterScenarioStep<CapturedRoute>(
            requestID: timeoutID,
            submissionIndex: 1,
            submissionEventIndex: 4,
            terminalEventIndex: 7,
            action: .push(.detail),
            context: .init(),
            observedState: .rootStack,
            observedRevision: 0,
            observedTerminal: .rejected,
            expectation: .init(state: .rootStack, revision: 0, terminal: .rejected)
        )
        let controls: [RouterScenarioControl] = [
            .submit(requestID: cancellationID, eventIndex: 0),
            .waitUntilStarted(requestID: cancellationID, eventIndex: 1),
            .cancel(requestID: cancellationID, eventIndex: 2),
            .awaitTerminal(requestID: cancellationID, eventIndex: 3),
            .submit(requestID: timeoutID, eventIndex: 4),
            .waitUntilStarted(requestID: timeoutID, eventIndex: 5),
            .advanceTime(nanoseconds: 30_000_000_000, eventIndex: 6),
            .awaitTerminal(requestID: timeoutID, eventIndex: 7),
        ]
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [cancelled, timedOut],
            controls: controls
        )
        let runtime = RouterTestRuntime()
        let (cancellationGate, cancellationContinuation) = AsyncStream<Void>.makeStream()
        let (timeoutGate, timeoutContinuation) = AsyncStream<Void>.makeStream()
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "remote") { transition in
                        let gate = transition.action == .push(.home)
                            ? cancellationGate
                            : timeoutGate
                        for await _ in gate { break }
                        return .allow
                    }
                ],
                policyTimeout: .seconds(30)
            ),
            exhaustivity: .off,
            runtime: runtime
        )

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: store)
        cancellationContinuation.finish()
        timeoutContinuation.finish()

        #expect(outcomes.map(RouterScenarioTerminal.init) == [.rejected, .rejected])
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Captured deferral decisions replay through the production continuation")
    func deferralDecisionControl() async throws {
        let configuration = RouterStoreConfiguration<CapturedRoute>(
            policies: [
                RouterPolicy(name: "approval") { transition in
                    transition.context.resumedDeferral == nil
                        ? .deferRequest(RouterDeferralID())
                        : .allow
                }
            ]
        )
        let source = RouterStore<CapturedRoute>(configuration: configuration)
        let recorder = RouterScenarioRecorder(store: source)

        guard case .deferred(_, _, _, let capturedDeferral) = await source.perform(
            .push(.detail)
        ) else {
            Issue.record("Expected source deferral")
            return
        }
        _ = await recorder.resolveDeferred(
            capturedDeferral.id,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        )
        #expect(await recorder.waitUntilCaptured(2))
        let captured = recorder.stop()
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal
            )
        })
        #expect(fixture.controls.contains { control in
            if case .resolveDeferral(
                _,
                let capturedID,
                .allow,
                .rebaseOnCurrentState,
                _
            ) = control {
                return capturedID == capturedDeferral.id
            }
            return false
        })

        let target = RouterTestStore<CapturedRoute>(
            configuration: configuration,
            exhaustivity: .off
        )
        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.map(RouterScenarioTerminal.init) == [.deferred, .applied])
        #expect(target.state.root == .stack(path: [.detail]))
        #expect(target.revision == 1)
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("A cancel deferral decision has distinct cancellation provenance")
    func cancelledDeferralDecisionControl() async throws {
        let configuration = RouterStoreConfiguration<CapturedRoute>(policies: [
            RouterPolicy(name: "approval") { transition in
                transition.context.resumedDeferral == nil
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
        ])
        let source = RouterStore<CapturedRoute>(configuration: configuration)
        let recorder = RouterScenarioRecorder(store: source)

        guard case .deferred(_, _, _, let deferral) = await source.perform(.push(.detail)) else {
            Issue.record("Expected source deferral")
            return
        }
        guard case .rejected(_, _, _, .cancelled) = await recorder.resolveDeferred(
            deferral.id,
            with: .cancel
        ) else {
            Issue.record("Expected cancelled deferral decision")
            return
        }

        let captured = recorder.stop()
        let cancelledStep = try #require(captured.steps.last)
        #expect(cancelledStep.cancellationOrigin == .deferralDecision)
        #expect(!captured.controls.contains { control in
            if case .cancel(let requestID, _) = control {
                return requestID == cancelledStep.requestID
            }
            return false
        })
        #expect(captured.controls.contains { control in
            if case .resolveDeferral(
                let requestID,
                deferral.id,
                .cancel,
                .requireUnchangedState,
                _
            ) = control {
                return requestID == cancelledStep.requestID
            }
            return false
        })

        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let target = RouterTestStore<CapturedRoute>(
            configuration: configuration,
            exhaustivity: .off
        )

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.map(RouterScenarioTerminal.init) == [.deferred, .rejected])
        #expect(target.state == .rootStack)
        #expect(target.revision == 0)
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("Queued history replay preserves its captured revision precondition")
    func queuedHistoryPreservesExpectedRevision() async throws {
        func configuration(_ gate: ScenarioGate) -> RouterStoreConfiguration<CapturedRoute> {
            var configuration = RouterStoreConfiguration<CapturedRoute>(policies: [
                RouterPolicy(name: "pause-detail") { transition in
                    if transition.action == .push(.detail) { await gate.pause() }
                    return .allow
                },
            ])
            configuration.runtimeDependencies.didQueueRequest = { _ in gate.release() }
            return configuration
        }

        let sourceGate = ScenarioGate()
        let source = RouterStore<CapturedRoute>(configuration: configuration(sourceGate))
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        let active = source.dispatch(.push(.detail))
        await sourceGate.waitUntilEntered()

        let historyOutcome = await history.goBack()
        _ = await active.value
        guard case .rejected(
            _,
            .rejected(_, _, _, .staleState(expectedRevision: 1, actualRevision: 2))
        ) = historyOutcome
        else {
            Issue.record("Expected queued history to preserve revision 1")
            history.stop()
            return
        }

        let captured = recorder.stop()
        let historyStep = try #require(captured.steps.first { $0.context.source == .history })
        #expect(historyStep.expectedRevision == 1)
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let targetGate = ScenarioGate()
        let target = RouterTestStore<CapturedRoute>(
            configuration: configuration(targetGate),
            exhaustivity: .off
        )

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.count == fixture.steps.count)
        guard case .rejected(_, _, _, let replayReason) = outcomes.last else {
            Issue.record("Expected replayed stale-state rejection")
            history.stop()
            return
        }
        #expect(RouterScenarioRejectionKind(replayReason) == .staleState)
        #expect(target.state.root == .stack(path: [.home, .detail]))
        #expect(target.revision == 2)
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test(
        "Cancellation of a deferral resume records and replays its exact cause",
        arguments: [false, true],
        [
            RouterDeferralResumeStrategy.requireUnchangedState,
            RouterDeferralResumeStrategy.rebaseOnCurrentState,
        ]
    )
    func cancelledDeferralResumeRecordsControl(
        historyMove: Bool,
        resumeStrategy: RouterDeferralResumeStrategy
    ) async throws {
        func configuration(_ gate: ScenarioGate) -> RouterStoreConfiguration<CapturedRoute> {
            .init(policies: [
                RouterPolicy(name: "approval") { transition in
                    let relevant = historyMove
                        ? transition.context.source == .history
                        : transition.action == .push(.detail)
                    return relevant && transition.context.resumedDeferral == nil
                        ? .deferRequest(RouterDeferralID())
                        : .allow
                },
                RouterPolicy(name: "pause-resume") { transition in
                    if transition.context.resumedDeferral != nil { await gate.pause() }
                    return .allow
                },
            ])
        }

        let sourceGate = ScenarioGate()
        let source = RouterStore<CapturedRoute>(configuration: configuration(sourceGate))
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        let deferred: RouterDeferredTransition
        if historyMove {
            _ = await source.perform(.push(.detail))
            guard case .deferred(_, .deferred(_, _, _, let value)) = await history.goBack()
            else {
                Issue.record("Expected deferred history request")
                history.stop()
                return
            }
            deferred = value
        } else {
            guard case .deferred(_, _, _, let value) = await source.perform(.push(.detail))
            else {
                Issue.record("Expected deferred action request")
                history.stop()
                return
            }
            deferred = value
        }

        let resumed = Task { @MainActor in
            await recorder.resolveDeferred(
                deferred.id,
                with: .allow,
                resumeStrategy: resumeStrategy
            )
        }
        await sourceGate.waitUntilEntered()
        resumed.cancel()
        guard case .rejected(_, _, _, .cancelled) = await resumed.value else {
            Issue.record("Expected cancelled resumed request")
            sourceGate.release()
            history.stop()
            return
        }
        sourceGate.release()

        let captured = recorder.stop()
        let cancelledStep = try #require(captured.steps.last)
        #expect(cancelledStep.cancellationOrigin == .request)
        #expect(captured.controls.contains { control in
            if case .cancel(let requestID, _) = control {
                return requestID == cancelledStep.requestID
            }
            return false
        })
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        _ = try RouterScenarioSourceGenerator.generate(
            fixture,
            routeTypeName: "CapturedRoute"
        )
        let targetGate = ScenarioGate()
        let target = RouterTestStore<CapturedRoute>(
            configuration: configuration(targetGate),
            exhaustivity: .off
        )

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        guard case .rejected(_, _, _, let replayReason) = outcomes.last else {
            Issue.record("Expected replayed cancellation")
            targetGate.release()
            history.stop()
            return
        }
        #expect(RouterScenarioRejectionKind(replayReason) == .cancelled)
        targetGate.release()
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test(
        "Queued deferral resumes retain cancellation ownership in capture and replay",
        arguments: [false, true]
    )
    func queuedDeferralResumeCancellation(historyMove: Bool) async throws {
        func configuration(
            _ gate: ScenarioGate,
            onQueue: @escaping @Sendable () -> Void = {}
        ) -> RouterStoreConfiguration<CapturedRoute> {
            var configuration = RouterStoreConfiguration<CapturedRoute>(policies: [
                RouterPolicy(name: "approval") { transition in
                    let shouldDefer = historyMove
                        ? transition.context.source == .history
                        : transition.action == .push(.detail)
                    return shouldDefer && transition.context.resumedDeferral == nil
                        ? .deferRequest(RouterDeferralID())
                        : .allow
                },
                RouterPolicy(name: "blocker") { transition in
                    if transition.action == .push(.home),
                       transition.context.source == .inspector {
                        await gate.pause()
                    }
                    return .allow
                },
            ])
            configuration.runtimeDependencies.didQueueRequest = { _ in onQueue() }
            return configuration
        }

        let sourceGate = ScenarioGate()
        let (queueEvents, queueContinuation) = AsyncStream<Void>.makeStream()
        var queueIterator = queueEvents.makeAsyncIterator()
        let source = RouterStore<CapturedRoute>(
            configuration: configuration(sourceGate) { queueContinuation.yield() }
        )
        let history = RouterHistory(store: source)
        if historyMove {
            _ = await source.perform(.push(.home))
            _ = await source.perform(.push(.detail))
        }
        let recorder = RouterScenarioRecorder(store: source)
        let deferred: RouterDeferredTransition
        if historyMove {
            guard case .deferred(_, .deferred(_, _, _, let value)) = await history.goBack()
            else {
                Issue.record("Expected deferred history request")
                history.stop()
                return
            }
            deferred = value
        } else {
            guard case .deferred(_, _, _, let value) = await source.perform(.push(.detail))
            else {
                Issue.record("Expected deferred action request")
                history.stop()
                return
            }
            deferred = value
        }

        let blocker = source.dispatch(
            .push(.home),
            context: .init(source: .inspector)
        )
        await sourceGate.waitUntilEntered()
        let resumed = Task { @MainActor in
            await recorder.resolveDeferred(
                deferred.id,
                with: .allow,
                resumeStrategy: .rebaseOnCurrentState
            )
        }
        _ = await queueIterator.next()
        resumed.cancel()
        guard case .rejected(_, _, _, .cancelled) = await resumed.value else {
            Issue.record("Expected queued resume cancellation")
            sourceGate.release()
            history.stop()
            return
        }
        blocker.cancel()
        guard case .rejected(_, _, _, .cancelled) = await blocker.value else {
            Issue.record("Expected blocker cancellation")
            sourceGate.release()
            history.stop()
            return
        }
        sourceGate.release()
        #expect(await recorder.waitUntilCaptured(3))

        let captured = recorder.stop()
        let resumedStep = try #require(captured.steps.first {
            $0.context.resumedDeferral == deferred.id
        })
        #expect(resumedStep.cancellationOrigin == .request)
        #expect(captured.controls.contains { control in
            if case .cancel(let requestID, _) = control {
                return requestID == resumedStep.requestID
            }
            return false
        })
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })

        let targetGate = ScenarioGate()
        let target = RouterTestStore<CapturedRoute>(
            initialState: fixture.initialState,
            configuration: configuration(targetGate),
            exhaustivity: .off
        )
        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.map(RouterScenarioTerminal.init) == [.deferred, .rejected, .rejected])
        #expect(outcomes.dropFirst().allSatisfy { outcome in
            guard case .rejected(_, _, _, let reason) = outcome else { return false }
            return RouterScenarioRejectionKind(reason) == .cancelled
        })
        #expect(target.state == fixture.initialState)
        #expect(target.revision == 0)
        targetGate.release()
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("Replay rejects cancellation claims and invalid revisions before execution")
    func replayRejectsMissingCancellationProvenanceAndInvalidRevision() async {
        let requestID = RouterTransitionID()
        let cancelledStep = RouterScenarioStep<CapturedRoute>(
            requestID: requestID,
            action: .push(.detail),
            context: .init(),
            observedState: .rootStack,
            observedRevision: 3,
            observedTerminal: .rejected,
            observedRejection: .cancelled,
            expectation: .init(
                state: .rootStack,
                revision: 3,
                terminal: .rejected,
                rejection: .cancelled
            )
        )
        let missingCause = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            initialRevision: 3,
            steps: [cancelledStep]
        )
        let target = RouterTestStore<CapturedRoute>(exhaustivity: .off)

        #expect(throws: RouterScenarioSourceGenerationError.missingCancellationProvenance(step: 0)) {
            _ = try RouterScenarioSourceGenerator.generate(
                missingCause,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.missingCancellationProvenance(step: 0)) {
            _ = try await RouterScenarioRunner.replay(missingCause, on: target)
        }

        let unfoundedCancelStep = RouterScenarioStep<CapturedRoute>(
            requestID: requestID,
            submissionEventIndex: 0,
            terminalEventIndex: 2,
            action: .push(.detail),
            context: .init(),
            observedState: .rootStack,
            observedRevision: 3,
            observedTerminal: .rejected,
            observedRejection: .cancelled,
            expectation: cancelledStep.expectation
        )
        let unfoundedCancel = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            initialRevision: 3,
            steps: [unfoundedCancelStep],
            controls: [
                .submit(requestID: requestID, eventIndex: 0),
                .cancel(requestID: requestID, eventIndex: 1),
                .awaitTerminal(requestID: requestID, eventIndex: 2),
            ]
        )
        #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
            _ = try RouterScenarioSourceGenerator.generate(
                unfoundedCancel,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
            _ = try await RouterScenarioRunner.replay(unfoundedCancel, on: target)
        }

        let invalidRevisionStep = RouterScenarioStep<CapturedRoute>(
            requestID: requestID,
            action: .push(.detail),
            context: .init(),
            expectedRevision: 2,
            observedState: .rootStack(path: [.detail]),
            observedRevision: 4,
            observedTerminal: .applied,
            expectation: .init(
                state: .rootStack(path: [.detail]),
                revision: 4,
                terminal: .applied
            )
        )
        let invalidRevision = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            initialRevision: 3,
            steps: [invalidRevisionStep]
        )
        #expect(throws: RouterScenarioSourceGenerationError.invalidExpectedRevision(step: 0)) {
            _ = try RouterScenarioSourceGenerator.generate(
                invalidRevision,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.invalidExpectedRevision(step: 0)) {
            _ = try await RouterScenarioRunner.replay(invalidRevision, on: target)
        }
        #expect(target.revision == 0)
        target.skipReceivedEvents()
        await target.finish()

        let overflowStep = RouterScenarioStep<CapturedRoute>(
            action: .push(.detail),
            context: .init(),
            expectedRevision: .max,
            observedState: .rootStack,
            observedRevision: 0,
            observedTerminal: .rejected,
            observedRejection: .staleState,
            expectation: .init(
                state: .rootStack,
                revision: 0,
                terminal: .rejected,
                rejection: .staleState
            )
        )
        let overflow = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [overflowStep]
        )
        let overflowTarget = RouterTestStore<CapturedRoute>(exhaustivity: .off)
        _ = await overflowTarget.send(.push(.home))
        _ = await overflowTarget.send(.pop(count: 1))
        #expect(overflowTarget.state == .rootStack)
        #expect(overflowTarget.revision == 2)

        await #expect(throws: RouterScenarioReplayError.invalidExpectedRevision(step: 0)) {
            _ = try await RouterScenarioRunner.replay(overflow, on: overflowTarget)
        }
        #expect(overflowTarget.revision == 2)
        overflowTarget.skipReceivedEvents()
        await overflowTarget.finish()
    }

    @Test(
        "Initial history requires its captured revision before any production request",
        arguments: [false, true]
    )
    func initialHistoryRejectsNullExpectedRevisionBeforeExecution(
        omitsKey: Bool
    ) async throws {
        let initialState = RouterState<CapturedRoute>.rootStack(path: [.home, .detail])
        let targetState = RouterState<CapturedRoute>.rootStack(path: [.home])
        let step = RouterScenarioStep<CapturedRoute>(
            action: .apply(RouterPlan(state: targetState)),
            context: .init(source: .history),
            requestSemantics: .historyNavigation(targetState),
            expectedRevision: 0,
            observedState: targetState,
            observedRevision: 1,
            observedTerminal: .applied,
            expectation: .init(
                state: targetState,
                revision: 1,
                terminal: .applied
            )
        )
        let validFixture = RouterScenarioFixture(
            initialState: initialState,
            steps: [step]
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(validFixture)
            ) as? [String: Any]
        )
        var steps = try #require(object["steps"] as? [[String: Any]])
        if omitsKey {
            steps[0].removeValue(forKey: "expectedRevision")
        } else {
            steps[0]["expectedRevision"] = NSNull()
        }
        object["steps"] = steps
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if omitsKey {
            #expect(throws: DecodingError.self) {
                _ = try RouterScenarioFixture<CapturedRoute>.decode(from: data)
            }
            return
        }
        let fixture = try RouterScenarioFixture<CapturedRoute>.decode(from: data)
        var policyCalls = 0
        let store = RouterTestStore<CapturedRoute>(
            initialState: initialState,
            configuration: .init(policies: [
                RouterPolicy(name: "must-not-run") { _ in
                    policyCalls += 1
                    return .allow
                },
            ]),
            exhaustivity: .off
        )

        #expect(throws: RouterScenarioSourceGenerationError.invalidExpectedRevision(step: 0)) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.invalidExpectedRevision(step: 0)) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }
        #expect(policyCalls == 0)
        #expect(store.state == initialState)
        #expect(store.revision == 0)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Captured history rebase preserves scenes during independent replay")
    func capturedHistoryRebasePreservesCurrentScenes() async throws {
        let configuration = RouterStoreConfiguration<CapturedRoute>(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history
                    && transition.context.resumedDeferral == nil
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
        ])
        let source = RouterStore<CapturedRoute>(configuration: configuration)
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        _ = await source.perform(.push(.detail))
        guard case .deferred(_, .deferred(_, _, _, let deferral)) = await history.goBack() else {
            Issue.record("Expected a deferred history move")
            return
        }
        let window = RouterWindow<CapturedRoute>(route: .window)
        _ = await source.perform(.openWindow(window))
        guard case .applied = await recorder.resolveDeferred(
            deferral.id,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the history move to resume")
            return
        }
        let captured = recorder.stop()
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let target = RouterTestStore<CapturedRoute>(
            configuration: configuration,
            exhaustivity: .off
        )

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.count == 5)
        #expect(target.state.root == .stack(path: [.home]))
        #expect(target.state.windows == [window])
        #expect(target.revision == source.revision)
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("Captured history preserves scenes that existed before submission")
    func capturedHistoryPreservesPreexistingScenes() async throws {
        let source = RouterStore<CapturedRoute>()
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        _ = await source.perform(.push(.detail))
        let window = RouterWindow<CapturedRoute>(route: .window)
        _ = await source.perform(.openWindow(window))
        guard case .completed = await history.goBack() else {
            Issue.record("Expected history navigation to complete")
            return
        }
        let captured = recorder.stop()
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let target = RouterTestStore<CapturedRoute>(exhaustivity: .off)

        _ = try RouterScenarioSourceGenerator.generate(
            fixture,
            routeTypeName: "CapturedRoute"
        )
        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.count == 4)
        #expect(target.state.root == .stack(path: [.home]))
        #expect(target.state.windows == [window])
        #expect(target.revision == source.revision)
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("Replay rejects a tampered resumed history action before execution")
    func replayRejectsTamperedResumedHistoryAction() async throws {
        let sourceConfiguration = RouterStoreConfiguration<CapturedRoute>(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history
                    && transition.context.resumedDeferral == nil
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
        ])
        let source = RouterStore<CapturedRoute>(configuration: sourceConfiguration)
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        _ = await source.perform(.push(.detail))
        guard case .deferred(_, .deferred(_, _, _, let deferral)) = await history.goBack()
        else {
            Issue.record("Expected a deferred history move")
            return
        }
        _ = await source.perform(.openWindow(RouterWindow(route: .window)))
        _ = await recorder.resolveDeferred(
            deferral.id,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        )
        let captured = try recorder.stop().settingExpectations(recorder.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let tamperedSteps = captured.steps.map { step in
            RouterScenarioStep<CapturedRoute>(
                requestID: step.requestID,
                submissionIndex: step.submissionIndex,
                submissionEventIndex: step.submissionEventIndex,
                terminalEventIndex: step.terminalEventIndex,
                action: step.context.resumedDeferral == nil
                    ? step.action
                    : .apply(RouterPlan(state: .rootStack(path: [.detail, .home]))),
                context: step.context,
                requestSemantics: step.requestSemantics,
                expectedRevision: step.expectedRevision,
                cancellationOrigin: step.cancellationOrigin,
                observedState: step.observedState,
                observedRevision: step.observedRevision,
                observedTerminal: step.observedTerminal,
                observedRejection: step.observedRejection,
                observedDeferralID: step.observedDeferralID,
                expectation: step.expectation
            )
        }
        let fixture = RouterScenarioFixture(
            initialState: captured.initialState,
            initialRevision: captured.initialRevision,
            metadata: captured.metadata,
            steps: tamperedSteps,
            controls: captured.controls,
            completeness: captured.completeness
        )
        var policyCalls = 0
        let target = RouterTestStore<CapturedRoute>(configuration: .init(policies: [
            RouterPolicy(name: "probe") { _ in
                policyCalls += 1
                return .allow
            },
        ]), exhaustivity: .off)

        #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
            _ = try await RouterScenarioRunner.replay(fixture, on: target)
        }
        #expect(policyCalls == 0)
        #expect(target.state == .rootStack)
        #expect(target.revision == 0)
        history.stop()
        await target.finish()
    }

    @Test("Replay rejects a tampered initial history action before execution")
    func replayRejectsTamperedInitialHistoryAction() async throws {
        let window = RouterWindow<CapturedRoute>(route: .window)
        let initialState = try RouterState<CapturedRoute>(
            root: .stack(path: [.home, .detail]),
            windows: [window]
        )
        let navigationTarget = RouterState<CapturedRoute>.rootStack(path: [.home])
        let expectedState = try RouterState<CapturedRoute>(
            root: .stack(path: [.home]),
            windows: [window]
        )
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: initialState,
            steps: [
                .init(
                    action: .apply(RouterPlan(state: .rootStack(path: [.detail]))),
                    context: .init(source: .history),
                    requestSemantics: .historyNavigation(navigationTarget),
                    expectedRevision: 0,
                    observedState: expectedState,
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(
                        state: expectedState,
                        revision: 1,
                        terminal: .applied
                    )
                ),
            ]
        )
        var policyCalls = 0
        let target = RouterTestStore<CapturedRoute>(
            initialState: initialState,
            configuration: .init(policies: [
                RouterPolicy(name: "probe") { _ in
                    policyCalls += 1
                    return .allow
                },
            ]),
            exhaustivity: .off
        )

        #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
            _ = try await RouterScenarioRunner.replay(fixture, on: target)
        }
        #expect(policyCalls == 0)
        #expect(target.state == initialState)
        #expect(target.revision == 0)
        await target.finish()
    }

    @Test(
        "Replay rejects unrepresented history lifetime invalidation before execution",
        arguments: [false, true]
    )
    func replayRejectsUnrepresentedHistoryLifetime(reset: Bool) async throws {
        let sourceConfiguration = RouterStoreConfiguration<CapturedRoute>(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history
                    && transition.context.resumedDeferral == nil
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
        ])
        let source = RouterStore<CapturedRoute>(configuration: sourceConfiguration)
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        _ = await source.perform(.push(.detail))
        guard case .deferred(_, .deferred(_, _, _, let deferral)) = await history.goBack()
        else {
            Issue.record("Expected a deferred history move")
            return
        }
        if reset {
            history.reset(sessionKey: "next-session")
        } else {
            history.stop()
        }
        guard case .rejected(_, _, let revision, .cancelled) = await recorder.resolveDeferred(
            deferral.id,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the stopped history lifetime to cancel its resume")
            return
        }
        #expect(revision == 2)
        let recorded = recorder.stop()
        let fixture = try recorded.settingExpectations(recorded.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        var policyCalls = 0
        let target = RouterTestStore<CapturedRoute>(configuration: .init(policies: [
            RouterPolicy(name: "probe") { _ in
                policyCalls += 1
                return .allow
            },
        ]), exhaustivity: .off)

        #expect(throws: RouterScenarioSourceGenerationError.unsupportedHistoryLifetime(step: 3)) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "CapturedRoute"
            )
        }
        await #expect(throws: RouterScenarioReplayError.unsupportedHistoryLifetime(step: 3)) {
            _ = try await RouterScenarioRunner.replay(fixture, on: target)
        }
        #expect(policyCalls == 0)
        #expect(target.state == .rootStack)
        #expect(target.revision == 0)
        history.stop()
        await target.finish()
    }

    @Test("Repeatedly deferred history replay preserves its original navigation intent")
    func repeatedHistoryDeferralPreservesRequestSemantics() async throws {
        let configuration = RouterStoreConfiguration<CapturedRoute>(policies: [
            RouterPolicy(name: "first-history-approval") { transition in
                transition.context.source == .history
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
            RouterPolicy(name: "second-history-approval") { transition in
                transition.context.source == .history
                    ? .deferRequest(RouterDeferralID())
                    : .allow
            },
        ])
        let source = RouterStore<CapturedRoute>(configuration: configuration)
        let history = RouterHistory(store: source)
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        _ = await source.perform(.push(.detail))
        guard case .deferred(_, .deferred(_, _, _, let firstDeferral)) = await history.goBack()
        else {
            Issue.record("Expected the first deferred history move")
            return
        }
        let firstWindow = RouterWindow<CapturedRoute>(route: .window)
        _ = await source.perform(.openWindow(firstWindow))
        guard case .deferred(_, _, _, let secondDeferral) = await recorder.resolveDeferred(
            firstDeferral.id,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the resumed history move to defer again")
            return
        }
        let secondWindow = RouterWindow<CapturedRoute>(route: .home)
        _ = await source.perform(.openWindow(secondWindow))
        guard case .applied = await recorder.resolveDeferred(
            secondDeferral.id,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the second resumed history move to apply")
            return
        }
        let captured = recorder.stop()
        let historySemantics = captured.steps.compactMap { step -> RouterState<CapturedRoute>? in
            guard case .historyNavigation(let target) = step.requestSemantics else { return nil }
            return target
        }
        #expect(historySemantics.count == 3)
        #expect(historySemantics.dropFirst().allSatisfy { $0 == historySemantics.first })
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })

        let target = RouterTestStore<CapturedRoute>(
            configuration: configuration,
            exhaustivity: .off
        )
        let outcomes = try await RouterScenarioRunner.replay(fixture, on: target)

        #expect(outcomes.count == 7)
        #expect(target.state.root == .stack(path: [.home]))
        #expect(target.state.windows == [firstWindow, secondWindow])
        #expect(target.revision == source.revision)
        history.stop()
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test("Delayed awaits validate each request's own completed outcome")
    func delayedAwaitUsesItsOwnCompletedOutcome() async throws {
        let firstID = RouterTransitionID()
        let secondID = RouterTransitionID()
        let firstState = RouterState<CapturedRoute>.rootStack(path: [.home])
        let secondState = RouterState<CapturedRoute>.rootStack(path: [.home, .detail])
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: firstID,
                    submissionEventIndex: 0,
                    terminalEventIndex: 3,
                    action: .push(.home),
                    context: .init(),
                    observedState: firstState,
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(state: firstState, revision: 1, terminal: .applied)
                ),
                .init(
                    requestID: secondID,
                    submissionIndex: 1,
                    submissionEventIndex: 1,
                    terminalEventIndex: 2,
                    action: .push(.detail),
                    context: .init(),
                    observedState: secondState,
                    observedRevision: 2,
                    observedTerminal: .applied,
                    expectation: .init(state: secondState, revision: 2, terminal: .applied)
                ),
            ],
            controls: [
                .submit(requestID: firstID, eventIndex: 0),
                .submit(requestID: secondID, eventIndex: 1),
                .awaitTerminal(requestID: secondID, eventIndex: 2),
                .awaitTerminal(requestID: firstID, eventIndex: 3),
            ]
        )
        let store = RouterTestStore<CapturedRoute>(exhaustivity: .off)

        let outcomes = try await RouterScenarioRunner.replay(fixture, on: store)

        #expect(outcomes.count == 2)
        #expect(store.state == secondState)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Replay preflight fails before production requests")
    func replayPreflightIsSideEffectFree() async {
        let metadata = RouterScenarioMetadata(
            routeSchemaID: String(describing: CapturedRoute.self),
            environmentID: "authenticated-app",
            environmentVersion: "2",
            dependencies: [.init(id: "session", version: "3", capabilities: ["signed-in"])],
            requiredCapabilities: [.applicationEffects],
            externalEffectIDs: ["load-account"]
        )
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            metadata: metadata,
            steps: []
        )
        let store = RouterTestStore<CapturedRoute>(exhaustivity: .off)

        await #expect(throws: RouterScenarioReplayError.environmentMismatch(
            expectedID: "authenticated-app",
            expectedVersion: "2"
        )) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }

        #expect(store.revision == 0)
        #expect(store.unassertedEvents.isEmpty)
        await store.finish()
    }

    @Test("Replay refuses a store whose state differs from the fixture baseline")
    func replayRequiresExactInitialState() async {
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: []
        )
        let store = RouterTestStore<CapturedRoute>(
            initialState: .rootStack(path: [.home]),
            exhaustivity: .off
        )

        await #expect(throws: RouterScenarioReplayError.initialStateMismatch) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 0)
        await store.finish()
    }

    @Test("Replay failure cancels and drains every request it owns")
    func replayFailureCleansUpOwnedRequests() async {
        let firstID = RouterTransitionID()
        let secondID = RouterTransitionID()
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: firstID,
                    submissionEventIndex: 0,
                    terminalEventIndex: 2,
                    action: .push(.home),
                    context: .init(),
                    observedState: .rootStack(path: [.home]),
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(
                        state: .rootStack(path: [.detail]),
                        revision: 1,
                        terminal: .applied
                    )
                ),
                .init(
                    requestID: secondID,
                    submissionIndex: 1,
                    submissionEventIndex: 1,
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
            ],
            controls: [
                .submit(requestID: firstID, eventIndex: 0),
                .submit(requestID: secondID, eventIndex: 1),
                .awaitTerminal(requestID: firstID, eventIndex: 2),
                .awaitTerminal(requestID: secondID, eventIndex: 3),
            ]
        )
        let probe = ScenarioCancellationProbe()
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "detail-gate") { transition in
                        guard transition.action == .push(.detail) else { return .allow }
                        return await probe.wait()
                    }
                ]
            ),
            exhaustivity: .off
        )

        await #expect(throws: RouterScenarioReplayError.stateMismatch(step: 0)) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 1)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("An unexpected replay deferral is cleaned up before the error returns")
    func unexpectedReplayDeferralIsCleanedUp() async {
        let deferralID = RouterDeferralID()
        let requestID = RouterTransitionID()
        let expectedState = RouterState<CapturedRoute>.rootStack(path: [.detail])
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: requestID,
                    action: .push(.detail),
                    context: .init(),
                    observedState: expectedState,
                    observedRevision: 1,
                    observedTerminal: .applied,
                    expectation: .init(
                        state: expectedState,
                        revision: 1,
                        terminal: .applied
                    )
                ),
            ]
        )
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { _ in .deferRequest(deferralID) }
                ]
            ),
            exhaustivity: .off
        )

        await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }
        #expect(store.pendingWork.deferrals == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        guard case .rejected(_, _, _, .deferralNotFound(deferralID)) =
                await store.resolveDeferred(deferralID, with: .allow).result else {
            Issue.record("Expected replay cleanup to consume its actual deferral")
            return
        }
        #expect(store.revision == 0)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Cancelling replay propagates to the active production request")
    func replayCancellationCleansUpOwnedRequests() async {
        let requestID = RouterTransitionID()
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: requestID,
                    terminalEventIndex: 2,
                    action: .push(.detail),
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
                .submit(requestID: requestID, eventIndex: 0),
                .waitUntilStarted(requestID: requestID, eventIndex: 1),
                .awaitTerminal(requestID: requestID, eventIndex: 2),
            ]
        )
        let probe = ScenarioCancellationProbe()
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in await probe.wait() }
                ]
            ),
            exhaustivity: .off
        )
        let replay = Task { @MainActor in
            try await RouterScenarioRunner.replay(fixture, on: store)
        }
        while !probe.entered { await Task.yield() }

        replay.cancel()
        do {
            _ = try await replay.value
            Issue.record("Expected replay cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(probe.cancelled)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Replay preflight validates schema, dependencies, capabilities, and effects")
    func replayPreflightMatrix() async {
        let schemaID = String(describing: CapturedRoute.self)
        let store = RouterTestStore<CapturedRoute>(exhaustivity: .off)

        func fixture(_ metadata: RouterScenarioMetadata) -> RouterScenarioFixture<CapturedRoute> {
            RouterScenarioFixture(initialState: .rootStack, metadata: metadata, steps: [])
        }

        await #expect(throws: RouterScenarioReplayError.routeSchemaMismatch(
            expected: "other-schema",
            actual: schemaID
        )) {
            _ = try await RouterScenarioRunner.replay(
                fixture(.init(routeSchemaID: "other-schema")),
                on: store
            )
        }

        let dependency = RouterScenarioDependency(
            id: "session",
            version: "3",
            capabilities: ["signed-in"]
        )
        let dependencyFixture = fixture(.init(
            routeSchemaID: schemaID,
            dependencies: [dependency]
        ))
        await #expect(throws: RouterScenarioReplayError.missingDependency(
            id: "session",
            version: "3"
        )) {
            _ = try await RouterScenarioRunner.replay(
                dependencyFixture,
                on: store,
                environment: .init(routeSchemaID: schemaID)
            )
        }
        await #expect(throws: RouterScenarioReplayError.missingDependencyCapability(
            dependencyID: "session",
            capability: "signed-in"
        )) {
            _ = try await RouterScenarioRunner.replay(
                dependencyFixture,
                on: store,
                environment: .init(
                    routeSchemaID: schemaID,
                    dependencies: [.init(id: "session", version: "3")]
                )
            )
        }

        let capabilityFixture = fixture(.init(
            routeSchemaID: schemaID,
            requiredCapabilities: [.deterministicClock]
        ))
        await #expect(throws: RouterScenarioReplayError.missingReplayCapability(
            .deterministicClock
        )) {
            _ = try await RouterScenarioRunner.replay(
                capabilityFixture,
                on: store,
                environment: .init(routeSchemaID: schemaID)
            )
        }

        let effectFixture = fixture(.init(
            routeSchemaID: schemaID,
            externalEffectIDs: ["load-account"]
        ))
        await #expect(throws: RouterScenarioReplayError.unsupportedExternalEffect(
            "load-account"
        )) {
            _ = try await RouterScenarioRunner.replay(
                effectFixture,
                on: store,
                environment: .init(routeSchemaID: schemaID)
            )
        }

        #expect(store.revision == 0)
        #expect(store.unassertedEvents.isEmpty)
        await store.finish()
    }

    @Test("Replay rejects a duplicate logical submission before production execution")
    func replayRejectsDuplicateLogicalSubmission() async {
        let requestID = RouterTransitionID()
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: requestID,
                    submissionEventIndex: 0,
                    terminalEventIndex: 1,
                    action: .push(.detail),
                    context: .init(),
                    observedState: .rootStack,
                    observedRevision: 0,
                    observedTerminal: .rejected,
                    expectation: .init(
                        state: .rootStack,
                        revision: 0,
                        terminal: .rejected
                    )
                ),
            ],
            controls: [
                .submit(requestID: requestID, eventIndex: 0),
                .awaitTerminal(requestID: requestID, eventIndex: 1),
                .submit(requestID: requestID, eventIndex: 2),
                .awaitTerminal(requestID: requestID, eventIndex: 3),
            ]
        )
        var policyCalls = 0
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(policies: [
                RouterPolicy(name: "deny") { _ in
                    policyCalls += 1
                    return .reject("denied")
                },
            ]),
            exhaustivity: .off
        )

        await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }
        #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "CapturedRoute"
            )
        }
        #expect(policyCalls == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Replay rejects tampered deferral resume steps before production execution")
    func replayRejectsTamperedDeferralResumeStep() async {
        let firstID = RouterTransitionID()
        let resumedID = RouterTransitionID()
        let deferralID = RouterDeferralID()
        let producer = RouterScenarioStep<CapturedRoute>(
            requestID: firstID,
            submissionIndex: 0,
            submissionEventIndex: 0,
            terminalEventIndex: 2,
            action: .push(.detail),
            context: .init(),
            observedState: .rootStack,
            observedRevision: 0,
            observedTerminal: .deferred,
            observedDeferralID: deferralID,
            expectation: .init(state: .rootStack, revision: 0, terminal: .deferred)
        )
        var resumedContext = RouterTransitionContext()
        resumedContext.resumedDeferral = deferralID
        let validResumed = RouterScenarioStep<CapturedRoute>(
            requestID: resumedID,
            submissionIndex: 1,
            submissionEventIndex: 4,
            terminalEventIndex: 5,
            action: .push(.detail),
            context: resumedContext,
            observedState: .rootStack(path: [.detail]),
            observedRevision: 1,
            observedTerminal: .applied,
            expectation: .init(
                state: .rootStack(path: [.detail]),
                revision: 1,
                terminal: .applied
            )
        )
        let controls: [RouterScenarioControl] = [
            .submit(requestID: firstID, eventIndex: 0),
            .waitUntilStarted(requestID: firstID, eventIndex: 1),
            .awaitTerminal(requestID: firstID, eventIndex: 2),
            .resolveDeferral(
                requestID: resumedID,
                deferralID: deferralID,
                resolution: .allow,
                resumeStrategy: .rebaseOnCurrentState,
                eventIndex: 3
            ),
            .awaitTerminal(requestID: resumedID, eventIndex: 5),
        ]
        let invalidResumedSteps = [
            RouterScenarioStep<CapturedRoute>(
                requestID: resumedID,
                submissionIndex: 1,
                submissionEventIndex: -1,
                terminalEventIndex: 5,
                action: validResumed.action,
                context: validResumed.context,
                observedState: validResumed.observedState,
                observedRevision: validResumed.observedRevision,
                observedTerminal: validResumed.observedTerminal,
                expectation: validResumed.expectation
            ),
            RouterScenarioStep<CapturedRoute>(
                requestID: resumedID,
                submissionIndex: 1,
                submissionEventIndex: 4,
                terminalEventIndex: 5,
                action: .push(.home),
                context: validResumed.context,
                observedState: validResumed.observedState,
                observedRevision: validResumed.observedRevision,
                observedTerminal: validResumed.observedTerminal,
                expectation: validResumed.expectation
            ),
            RouterScenarioStep<CapturedRoute>(
                requestID: resumedID,
                submissionIndex: 1,
                submissionEventIndex: 4,
                terminalEventIndex: 5,
                action: validResumed.action,
                context: .init(),
                observedState: validResumed.observedState,
                observedRevision: validResumed.observedRevision,
                observedTerminal: validResumed.observedTerminal,
                expectation: validResumed.expectation
            ),
        ]
        var policyCalls = 0
        let store = RouterTestStore<CapturedRoute>(
            configuration: .init(policies: [
                RouterPolicy(name: "probe") { _ in
                    policyCalls += 1
                    return .allow
                },
            ]),
            exhaustivity: .off
        )

        for resumed in invalidResumedSteps {
            let fixture = RouterScenarioFixture<CapturedRoute>(
                initialState: .rootStack,
                steps: [producer, resumed],
                controls: controls
            )
            await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
                _ = try await RouterScenarioRunner.replay(fixture, on: store)
            }
            #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
                _ = try RouterScenarioSourceGenerator.generate(
                    fixture,
                    routeTypeName: "CapturedRoute"
                )
            }
        }
        let nonDeferredProducer = RouterScenarioStep<CapturedRoute>(
            requestID: firstID,
            submissionIndex: 0,
            submissionEventIndex: 0,
            terminalEventIndex: 2,
            action: producer.action,
            context: producer.context,
            observedState: .rootStack(path: [.detail]),
            observedRevision: 1,
            observedTerminal: .applied,
            expectation: .init(
                state: .rootStack(path: [.detail]),
                revision: 1,
                terminal: .applied
            )
        )
        let secondResumedID = RouterTransitionID()
        let secondResumed = RouterScenarioStep<CapturedRoute>(
            requestID: secondResumedID,
            submissionIndex: 2,
            submissionEventIndex: 7,
            terminalEventIndex: 8,
            action: validResumed.action,
            context: resumedContext,
            observedState: validResumed.observedState,
            observedRevision: validResumed.observedRevision,
            observedTerminal: validResumed.observedTerminal,
            expectation: validResumed.expectation
        )
        let invalidGraphFixtures = [
            RouterScenarioFixture<CapturedRoute>(
                initialState: .rootStack,
                steps: [producer, validResumed],
                controls: [
                    .submit(requestID: firstID, eventIndex: 0),
                    .resolveDeferral(
                        requestID: resumedID,
                        deferralID: deferralID,
                        resolution: .allow,
                        resumeStrategy: .rebaseOnCurrentState,
                        eventIndex: 1
                    ),
                    .awaitTerminal(requestID: firstID, eventIndex: 2),
                    .awaitTerminal(requestID: resumedID, eventIndex: 5),
                ]
            ),
            RouterScenarioFixture<CapturedRoute>(
                initialState: .rootStack,
                steps: [nonDeferredProducer, validResumed],
                controls: controls
            ),
            RouterScenarioFixture<CapturedRoute>(
                initialState: .rootStack,
                steps: [producer, validResumed],
                controls: controls + [
                    .awaitTerminal(requestID: resumedID, eventIndex: 6),
                ]
            ),
            RouterScenarioFixture<CapturedRoute>(
                initialState: .rootStack,
                steps: [producer, validResumed, secondResumed],
                controls: controls + [
                    .resolveDeferral(
                        requestID: secondResumedID,
                        deferralID: deferralID,
                        resolution: .allow,
                        resumeStrategy: .rebaseOnCurrentState,
                        eventIndex: 6
                    ),
                    .awaitTerminal(requestID: secondResumedID, eventIndex: 8),
                ]
            ),
        ]
        for fixture in invalidGraphFixtures {
            await #expect(throws: RouterScenarioReplayError.invalidEventOrdering) {
                _ = try await RouterScenarioRunner.replay(fixture, on: store)
            }
            #expect(throws: RouterScenarioSourceGenerationError.invalidEventOrdering) {
                _ = try RouterScenarioSourceGenerator.generate(
                    fixture,
                    routeTypeName: "CapturedRoute"
                )
            }
        }
        #expect(policyCalls == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Replay distinguishes rejection categories")
    func rejectionReasonMismatchFails() async {
        let requestID = RouterTransitionID()
        let fixture = RouterScenarioFixture<CapturedRoute>(
            initialState: .rootStack,
            steps: [
                .init(
                    requestID: requestID,
                    action: .pop(count: 1),
                    context: .init(),
                    observedState: .rootStack,
                    observedRevision: 0,
                    observedTerminal: .rejected,
                    observedRejection: .mutation,
                    expectation: .init(
                        state: .rootStack,
                        revision: 0,
                        terminal: .rejected,
                        rejection: .cancelled
                    )
                ),
            ]
        )
        let store = RouterTestStore<CapturedRoute>(exhaustivity: .off)

        await #expect(throws: RouterScenarioReplayError.rejectionMismatch(
            step: 0,
            expected: .cancelled,
            actual: .mutation
        )) {
            _ = try await RouterScenarioRunner.replay(fixture, on: store)
        }
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Incomplete and capacity-truncated captures cannot generate passing tests")
    func incompleteCaptureFailsClosed() async throws {
        let store = RouterStore<CapturedRoute>()
        let recorder = RouterScenarioRecorder(store: store, capacity: 1)

        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))
        #expect(await recorder.waitUntilObserved(2))
        let fixture = recorder.stop()

        #expect(!fixture.completeness.isComplete)
        #expect(fixture.completeness.droppedStepCount == 1)
        #expect(throws: RouterScenarioSourceGenerationError.incomplete(fixture.completeness)) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "CapturedRoute"
            )
        }
        #expect(throws: RouterScenarioSourceGenerationError.invalidSwiftIdentifier("bad-name")) {
            let complete = RouterScenarioFixture<CapturedRoute>(
                initialState: .rootStack,
                steps: [],
                completeness: .init()
            )
            _ = try RouterScenarioSourceGenerator.generate(
                complete,
                routeTypeName: "CapturedRoute",
                testName: "bad-name"
            )
        }
    }

    @Test("Capture preserves request order when a later request terminates first")
    func preservesRequestOrder() async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<CapturedRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    },
                ],
                schedulingPolicy: .rejectWhileBusy
            )
        )
        let recorder = RouterScenarioRecorder(store: store)
        var events = store.events.makeAsyncIterator()
        let first = Task { @MainActor in
            await store.perform(.push(.home))
        }
        guard case .started = await events.next() else {
            Issue.record("Expected the first request to start")
            continuation.finish()
            return
        }

        _ = await store.perform(.push(.detail))
        continuation.yield()
        continuation.finish()
        _ = await first.value
        #expect(await recorder.waitUntilCaptured(2))

        let fixture = recorder.stop()
        #expect(fixture.steps.map(\.action) == [.push(.home), .push(.detail)])
        #expect(fixture.steps.map(\.observedTerminal) == [.applied, .rejected])
        #expect(fixture.completeness.unpairedRequestCount == 0)
    }

    @Test("A stalled request cannot grow the pending correlation buffer without bound")
    func pendingCorrelationIsBounded() async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<CapturedRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    },
                ],
                schedulingPolicy: .rejectWhileBusy
            )
        )
        let recorder = RouterScenarioRecorder(store: store, capacity: 1)
        var events = store.events.makeAsyncIterator()
        let first = Task { @MainActor in
            await store.perform(.push(.home))
        }
        guard case .started = await events.next() else {
            Issue.record("Expected the first request to start")
            continuation.finish()
            return
        }

        for _ in 0..<300 {
            _ = await store.perform(.push(.detail))
        }
        #expect(!(await recorder.waitUntilObserved(301)))
        let fixture = recorder.stop()
        #expect(fixture.completeness.unpairedRequestCount > 0)

        continuation.yield()
        continuation.finish()
        _ = await first.value
    }
}
