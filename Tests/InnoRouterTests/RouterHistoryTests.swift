import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum HistoryRoute: String, Route, Codable {
    case home
    case detail
    case settings
    case modal
    case window
}

@Suite("RouterHistory")
@MainActor
struct RouterHistoryTests {
    @MainActor
    private final class PolicyGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        func waitUntilEntered() async {
            if continuation != nil { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class QueueSignal {
        private var count = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func record() {
            count += 1
            let waiters = waiters
            self.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitForFirstRequest() async {
            if count > 0 { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @Test("Validated fallback, repeated approval, history, and checkpoint stay coherent")
    func restorationHistoryDeferralIntegration() async throws {
        let firstApproval = RouterDeferralID()
        let secondApproval = RouterDeferralID()
        let store = RouterStore<HistoryRoute>(configuration: .init(policies: [
            RouterPolicy(name: "first") { transition in
                transition.context.source == .history ? .deferRequest(firstApproval) : .allow
            },
            RouterPolicy(name: "second") { transition in
                transition.context.source == .history ? .deferRequest(secondApproval) : .allow
            },
        ]))
        let validator = RouterPartialRestorationValidator<HistoryRoute>(
            fallback: { _ in .detail },
            validate: { route, _ in
                switch route {
                case .home: return .remove(reason: "deleted")
                case .detail: return .replace(with: .settings, reason: "migrated")
                default: return .keep
                }
            }
        )
        let history = RouterHistory(store: store, validator: validator)
        let codec = try RouterSnapshotCodec<HistoryRoute>(currentVersion: 1)
        let snapshot = try codec.encode(.rootStack(path: [.home]))

        _ = try await store.restorePartially(
            from: snapshot,
            using: codec,
            validator: validator
        )
        #expect(await history.waitUntilRecordedRevision(1))
        #expect(store.state == .rootStack(path: [.settings]))
        guard case .success = history.createCheckpoint(named: "normalized") else {
            Issue.record("Expected normalized checkpoint")
            return
        }
        _ = await store.perform(.push(.window))

        guard case .deferred = await history.goBack(),
              case .deferred = await store.resumeDeferred(firstApproval),
              case .applied = await store.resumeDeferred(secondApproval) else {
            Issue.record("Expected repeated approval to restore normalized history")
            return
        }
        #expect(store.state == .rootStack(path: [.settings]))
        #expect(history.currentEntry.navigationState == store.state)
        _ = await store.perform(.push(.window))
        guard case .deferred = await history.restoreCheckpoint(named: "normalized"),
              case .deferred = await store.resumeDeferred(firstApproval),
              case .applied = await store.resumeDeferred(secondApproval) else {
            Issue.record("Expected checkpoint restoration approvals")
            return
        }
        guard case .success(let immediate) = history.createCheckpoint(named: "immediate") else {
            Issue.record("Expected immediate checkpoint")
            return
        }
        #expect(immediate.entry.navigationState == store.state)
        #expect(history.currentEntry.navigationState == store.state)
        history.stop()
    }

    @Test("Cancelled history waiters complete without a commit")
    func cancelledHistoryWaitersComplete() async {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(store: store)
        let count = Task { @MainActor in await history.waitUntilRecorded(2) }
        let revision = Task { @MainActor in await history.waitUntilRecordedRevision(1) }

        count.cancel()
        revision.cancel()

        #expect(await count.value == false)
        #expect(await revision.value == false)
        history.stop()
    }

    @Test("Back, forward, checkpoint, capacity, and branching keep one store authoritative")
    func navigationAndCheckpoints() async {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(
            store: store,
            configuration: .init(capacity: 3, checkpointCapacity: 1, sessionKey: "account-a")
        )

        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))
        #expect(await history.waitUntilRecorded(3))
        #expect(history.entries.count == 3)
        #expect(history.cursor == 2)

        guard case .success(let checkpoint) = history.createCheckpoint(named: "detail") else {
            Issue.record("Expected checkpoint")
            return
        }
        #expect(checkpoint.sessionKey == "account-a")
        #expect(history.createCheckpoint(named: "detail") == .failure(
            .checkpointAlreadyExists("detail")
        ))
        #expect(history.createCheckpoint(named: "other") == .failure(
            .checkpointCapacityExceeded(limit: 1)
        ))

        guard case .completed(let backCursor, _) = await history.goBack() else {
            Issue.record("Expected history back")
            return
        }
        #expect(backCursor == 1)
        #expect(store.state.root == .stack(path: [.home]))

        guard case .completed(let forwardCursor, _) = await history.goForward() else {
            Issue.record("Expected history forward")
            return
        }
        #expect(forwardCursor == 2)
        #expect(store.state.root == .stack(path: [.home, .detail]))

        _ = await history.goBack()
        _ = await store.perform(.push(.settings))
        #expect(await history.waitUntilRecordedRevision(store.revision))
        #expect(!history.canGoForward)
        #expect(history.entries.last?.navigationState.root == .stack(path: [.home, .settings]))

        guard case .completed(_, _) = await history.restoreCheckpoint(named: "detail") else {
            Issue.record("Expected checkpoint restoration")
            return
        }
        #expect(store.state.root == .stack(path: [.home, .detail]))

        history.reset(sessionKey: "account-b")
        #expect(history.entries.count == 1)
        #expect(history.checkpoints.isEmpty)
        #expect(!history.canGoBack)
        history.stop()
    }

    @Test("Policy rejection preserves state and cursor")
    func policyFailureDoesNotMoveCursor() async {
        let store = RouterStore<HistoryRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "history-lock") { transition in
                        transition.context.source == .history ? .reject("locked") : .allow
                    },
                ]
            )
        )
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        #expect(await history.waitUntilRecorded(2))

        let before = store.state
        let cursor = history.cursor
        let result = await history.goBack()

        guard case .rejected(let resultCursor, let transition) = result,
              case .rejected(_, _, _, .policy(name: "history-lock", message: "locked")) = transition else {
            Issue.record("Expected policy-rejected history move")
            return
        }
        #expect(resultCursor == cursor)
        #expect(history.cursor == cursor)
        #expect(store.state == before)
        history.stop()
    }

    @Test("Modal and badges are never rewound by path history")
    func preservesTransientStateAndRejectsModalConflict() async throws {
        let tabs = try RouterContainerState<HistoryRoute>(
            style: .tabs,
            selection: "main",
            branches: [
                .init(id: "main"),
                .init(id: "settings"),
            ]
        )
        let store = RouterStore(initialState: try RouterState(root: .container(tabs)))
        let history = RouterHistory(store: store)
        _ = await store.perform(RouterAction.push(.detail).inScope("main"))
        #expect(await history.waitUntilRecorded(2))
        _ = await store.perform(RouterAction.setBadge(7, for: "settings"))
        _ = await store.perform(
            RouterAction.present(.init(route: .modal, style: .sheet)).inScope("main")
        )

        let cursor = history.cursor
        let before = store.state
        let result = await history.goBack()

        #expect(result == .unavailable(
            cursor: cursor,
            reason: .activePresentation(RouterScopePath(["main"]))
        ))
        #expect(history.cursor == cursor)
        #expect(store.state == before)
        guard case .container(let current) = store.state.root else {
            Issue.record("Expected tabs")
            return
        }
        #expect(current.badges["settings"] == 7)
        history.stop()
    }

    @Test("Past scene inventory never reopens a scene that has disappeared")
    func doesNotReopenScenes() async throws {
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let initial = try RouterState<HistoryRoute>(
            windows: [.init(id: windowID, route: .window, node: .stack(path: [.detail]))]
        )
        let store = RouterStore(initialState: initial)
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        #expect(await history.waitUntilRecorded(2))
        _ = await store.perform(.dismissWindow(windowID))
        #expect(store.state.windows.isEmpty)

        guard case .completed = await history.goBack() else {
            Issue.record("Expected history back")
            return
        }
        #expect(store.state.root == .stack())
        #expect(store.state.windows.isEmpty)
        history.stop()
    }

    @Test("Non-navigation commits satisfy revision barriers without creating history")
    @MainActor
    func nonNavigationRevisionBarrier() async throws {
        let tabs = try RouterContainerState<HistoryRoute>(
            style: .tabs,
            selection: "main",
            branches: [.init(id: "main"), .init(id: "settings")]
        )
        let store = RouterStore(initialState: try RouterState(root: .container(tabs)))
        let history = RouterHistory(store: store)

        _ = await store.perform(.setBadge(3, for: "settings"))
        #expect(await history.waitUntilRecordedRevision(1))
        #expect(history.entries.count == 1)
        history.stop()
    }

    @Test("Checkpoint observes the latest commit without an asynchronous race")
    func checkpointIsSynchronousWithCommit() async {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(store: store)

        _ = await store.perform(.push(.home))
        guard case .success(let checkpoint) = history.createCheckpoint(named: "home") else {
            Issue.record("Expected checkpoint")
            return
        }

        #expect(checkpoint.entry.navigationState.root == .stack(path: [.home]))
        #expect(checkpoint.entry.sourceRevision == 1)
        history.stop()
    }

    @Test("Deferred moves update the cursor only after their commit")
    func deferredMoveCompletesCursorOnResume() async {
        let deferralID = RouterDeferralID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        )
        let store = RouterStore<HistoryRoute>(configuration: .init(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history ? .deferRequest(deferralID) : .allow
            },
        ]))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))

        guard case .deferred(let pendingCursor, _) = await history.goBack() else {
            Issue.record("Expected deferred history move")
            return
        }
        #expect(pendingCursor == 1)
        #expect(history.cursor == 1)

        guard case .applied = await store.resumeDeferred(deferralID) else {
            Issue.record("Expected resumed history commit")
            return
        }
        #expect(history.cursor == 0)
        #expect(store.state.root == .stack())
        history.stop()
    }

    @Test("A history move remains correlated across repeated deferrals")
    func historySurvivesSecondDeferral() async {
        let first = RouterDeferralID()
        let second = RouterDeferralID()
        let store = RouterStore<HistoryRoute>(configuration: .init(policies: [
            RouterPolicy(name: "first") { transition in
                transition.context.source == .history ? .deferRequest(first) : .allow
            },
            RouterPolicy(name: "second") { transition in
                transition.context.source == .history ? .deferRequest(second) : .allow
            },
        ]))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))

        guard case .deferred = await history.goBack(),
              case .deferred = await store.resumeDeferred(first),
              case .applied = await store.resumeDeferred(second) else {
            Issue.record("Expected the history move to cross two approvals")
            return
        }

        #expect(store.state == .rootStack(path: [.home]))
        #expect(history.cursor == 1)
        #expect(history.currentEntry.navigationState == store.state)
        history.stop()
    }

    @Test("A rebased history move preserves scenes and rejects a new modal conflict")
    func historyRebasePreservesCurrentLifetimes() async throws {
        let deferralID = RouterDeferralID()
        let store = RouterStore<HistoryRoute>(configuration: .init(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history && transition.context.resumedDeferral == nil
                    ? .deferRequest(deferralID)
                    : .allow
            },
        ]))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))
        guard case .deferred = await history.goBack() else {
            Issue.record("Expected a deferred history move")
            return
        }
        let cursor = history.cursor
        let window = RouterWindow<HistoryRoute>(route: .window)
        let modal = RouterPresentation<HistoryRoute>(route: .modal, style: .sheet)
        _ = await store.perform(.openWindow(window))
        _ = await store.perform(.present(modal))
        let beforeResume = store.state

        let outcome = await store.resumeDeferred(
            deferralID,
            strategy: .rebaseOnCurrentState
        )

        guard case .rejected(_, _, _, .mutation(.blockedByPresentation(.root))) = outcome else {
            Issue.record("Expected the new modal to block rebased history")
            return
        }
        #expect(store.state == beforeResume)
        #expect(history.cursor == cursor)
        history.stop()
    }

    @Test("A rebased history move reports incompatible current topology")
    func historyRebaseRejectsIncompatibleTopology() async throws {
        let deferralID = RouterDeferralID()
        let tabs = try RouterContainerState<HistoryRoute>(
            style: .tabs,
            selection: "main",
            branches: [.init(id: "main"), .init(id: "settings")]
        )
        let store = RouterStore(
            initialState: try RouterState(root: .container(tabs)),
            configuration: .init(policies: [
                RouterPolicy(name: "history-approval") { transition in
                    transition.context.source == .history
                        && transition.context.resumedDeferral == nil
                        ? .deferRequest(deferralID)
                        : .allow
                },
            ])
        )
        let history = RouterHistory(store: store)
        _ = await store.perform(RouterAction.push(.home).inScope("main"))
        _ = await store.perform(RouterAction.push(.detail).inScope("main"))
        guard case .deferred = await history.goBack() else {
            Issue.record("Expected a deferred history move")
            return
        }
        _ = await store.perform(.apply(.init(state: .rootStack(path: [.settings]))))
        let beforeResume = store.state
        let cursor = history.cursor

        let outcome = await store.resumeDeferred(
            deferralID,
            strategy: .rebaseOnCurrentState
        )

        guard case .rejected(
            _,
            _,
            _,
            .mutation(.incompatibleNavigationTopology(.root))
        ) = outcome else {
            Issue.record("Expected an incompatible topology rejection")
            return
        }
        #expect(store.state == beforeResume)
        #expect(history.cursor == cursor)
        history.stop()
    }

    @Test("A safe rebased history move preserves a newly opened window")
    func safeHistoryRebasePreservesNewWindow() async {
        let deferralID = RouterDeferralID()
        let store = RouterStore<HistoryRoute>(configuration: .init(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history && transition.context.resumedDeferral == nil
                    ? .deferRequest(deferralID)
                    : .allow
            },
        ]))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))
        guard case .deferred = await history.goBack() else {
            Issue.record("Expected a deferred history move")
            return
        }
        let window = RouterWindow<HistoryRoute>(route: .window)
        _ = await store.perform(.openWindow(window))

        let outcome = await store.resumeDeferred(
            deferralID,
            strategy: .rebaseOnCurrentState
        )

        guard case .applied = outcome else {
            Issue.record("Expected a safe rebased history move")
            return
        }
        #expect(store.state.root == .stack(path: [.home]))
        #expect(store.state.windows == [window])
        #expect(history.cursor == 1)
        history.stop()
    }

    @Test("A queued history rebase prepares against executor-entry state")
    func queuedHistoryRebaseUsesExecutorEntryState() async {
        let deferralID = RouterDeferralID()
        let gate = PolicyGate()
        let queueSignal = QueueSignal()
        var configuration = RouterStoreConfiguration<HistoryRoute>(policies: [
            RouterPolicy(name: "history-approval-and-window-gate") { transition in
                if transition.context.source == .history,
                   transition.context.resumedDeferral == nil {
                    return .deferRequest(deferralID)
                }
                if case .openWindow = transition.action {
                    await gate.wait()
                }
                return .allow
            },
        ])
        configuration.runtimeDependencies.didQueueRequest = { _ in
            queueSignal.record()
        }
        let store = RouterStore<HistoryRoute>(configuration: configuration)
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))
        guard case .deferred = await history.goBack() else {
            Issue.record("Expected a deferred history move")
            return
        }

        let window = RouterWindow<HistoryRoute>(route: .window)
        let windowRequest = Task { @MainActor in
            await store.perform(.openWindow(window))
        }
        await gate.waitUntilEntered()
        let historyRequest = Task { @MainActor in
            await store.resumeDeferred(deferralID, strategy: .rebaseOnCurrentState)
        }
        await queueSignal.waitForFirstRequest()
        gate.release()

        guard case .applied = await windowRequest.value,
              case .applied = await historyRequest.value else {
            Issue.record("Expected the window and queued history move to commit")
            return
        }
        #expect(store.state.root == .stack(path: [.home]))
        #expect(store.state.windows == [window])
        #expect(history.cursor == 1)
        history.stop()
    }

    @Test("Reset invalidates a deferred move from the previous session")
    func resetInvalidatesDeferredMove() async {
        let deferralID = RouterDeferralID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        )
        let store = RouterStore<HistoryRoute>(configuration: .init(policies: [
            RouterPolicy(name: "history-approval") { transition in
                transition.context.source == .history ? .deferRequest(deferralID) : .allow
            },
        ]))
        let history = RouterHistory(
            store: store,
            configuration: .init(sessionKey: "account-a")
        )
        _ = await store.perform(.push(.home))
        guard case .deferred = await history.goBack() else {
            Issue.record("Expected deferred history move")
            return
        }

        history.reset(sessionKey: "account-b")
        guard case .rejected(_, _, _, .cancelled) = await store.resumeDeferred(
            deferralID,
            strategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the previous session move to be cancelled")
            return
        }
        #expect(history.cursor == 0)
        #expect(history.entries.count == 1)
        #expect(store.state.root == .stack(path: [.home]))
        history.stop()
    }

    @Test("Stopped history rejects further movement without touching the store")
    func stoppedHistoryIsTerminal() async {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.home))
        history.stop()

        #expect(await history.goBack() == .unavailable(cursor: 1, reason: .stopped))
        #expect(store.state.root == .stack(path: [.home]))
        #expect(store.revision == 1)
    }

    @Test("History reuses partial restoration validation before applying an entry")
    func validatesHistoricalRoutes() async throws {
        let initial = RouterState<HistoryRoute>.rootStack(path: [.home, .detail])
        let store = RouterStore(initialState: initial)
        let history = RouterHistory(
            store: store,
            validator: .init { route, _ in
                route == .detail ? .remove(reason: "expired") : .keep
            }
        )
        _ = await store.perform(.push(.settings))

        guard case .completed = await history.goBack() else {
            Issue.record("Expected validated history move")
            return
        }
        #expect(store.state.root == .stack(path: [.home]))
        #expect(history.lastRestorationReport?.entries.map(\.change) == [
            .kept,
            .removed,
        ])
        history.stop()
    }

    @Test("History freezes its expected revision before awaiting route validation")
    func validationAwaitPreservesSubmissionRevision() async throws {
        let gate = PolicyGate()
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(
            store: store,
            validator: .init { _, _ in
                await gate.wait()
                return .keep
            }
        )
        _ = await store.perform(.push(.home))
        #expect(await history.waitUntilRecordedRevision(1))
        _ = await store.perform(.push(.detail))
        #expect(await history.waitUntilRecordedRevision(2))

        let move = Task { @MainActor in await history.goBack() }
        await gate.waitUntilEntered()
        _ = await store.perform(.push(.settings))
        #expect(store.revision == 3)
        gate.release()

        guard case .rejected(
            _,
            .rejected(_, _, _, .staleState(expectedRevision: 2, actualRevision: 3))
        ) = await move.value else {
            Issue.record("Expected validation-delayed history to retain revision 2")
            history.stop()
            return
        }
        #expect(store.state == .rootStack(path: [.home, .detail, .settings]))
        #expect(store.revision == 3)
        history.stop()
    }

    @Test("Checkpoint entries reflect the state produced by restoration validation")
    func checkpointReflectsValidatedReplacement() async {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(store: store, validator: .init { route, _ in
            route == .home ? .replace(with: .settings, reason: "retired") : .keep
        })
        _ = await store.perform(.push(.home))
        _ = history.createCheckpoint(named: "saved")
        _ = await store.perform(.push(.detail))

        guard case .completed = await history.restoreCheckpoint(named: "saved") else {
            Issue.record("Expected checkpoint restoration")
            return
        }
        #expect(store.state == .rootStack(path: [.settings]))
        #expect(history.currentEntry.navigationState == store.state)
        guard case .success(let refreshed) = history.createCheckpoint(named: "again") else {
            Issue.record("Expected a refreshed checkpoint")
            return
        }
        #expect(refreshed.entry.navigationState == store.state)
        history.stop()
    }

    @Test("Reset rejects commits buffered by the previous session")
    func resetRejectsBufferedCommits() async {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(
            store: store,
            configuration: .init(sessionKey: "account-a")
        )

        _ = await store.perform(.push(.home))
        _ = await store.perform(.push(.detail))
        history.reset(sessionKey: "account-b")
        _ = await store.perform(.push(.settings))
        #expect(await history.waitUntilRecordedRevision(3))

        #expect(history.entries.map(\.navigationState.root) == [
            .stack(path: [.home, .detail]),
            .stack(path: [.home, .detail, .settings]),
        ])
        #expect(history.cursor == 1)
        history.stop()
    }

    @Test("Checkpoint import validates name, session, version, and collisions")
    @MainActor
    func checkpointImportBoundaries() throws {
        let store = RouterStore<HistoryRoute>()
        let history = RouterHistory(
            store: store,
            configuration: .init(checkpointCapacity: 2, sessionKey: "account-a")
        )
        let entry = RouterHistoryEntry(
            navigationState: RouterState<HistoryRoute>.rootStack(path: [.home]),
            sourceRevision: 1
        )
        let checkpoint = RouterHistoryCheckpoint(
            name: "home",
            sessionKey: "account-a",
            entry: entry
        )

        #expect(history.importCheckpoint(checkpoint) == .success(checkpoint))
        #expect(history.importCheckpoint(checkpoint) == .failure(
            .checkpointAlreadyExists("home")
        ))
        #expect(history.importCheckpoint(checkpoint, collision: .replace) == .success(
            checkpoint
        ))

        let wrongSession = RouterHistoryCheckpoint(
            name: "other",
            sessionKey: "account-b",
            entry: entry
        )
        #expect(history.importCheckpoint(wrongSession) == .failure(
            .sessionMismatch(expected: "account-a", actual: "account-b")
        ))
        let blank = RouterHistoryCheckpoint(
            name: "   ",
            sessionKey: "account-a",
            entry: entry
        )
        #expect(history.importCheckpoint(blank) == .failure(.invalidCheckpointName))

        let encoded = try JSONEncoder().encode(checkpoint)
        let futureData = try #require(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "\"formatVersion\":1",
                with: "\"formatVersion\":2"
            ).data(using: .utf8)
        )
        let future = try JSONDecoder().decode(
            RouterHistoryCheckpoint<HistoryRoute>.self,
            from: futureData
        )
        #expect(history.importCheckpoint(future) == .failure(
            .unsupportedCheckpointVersion(2)
        ))
        history.stop()
    }
}
