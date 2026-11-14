import Foundation
import SwiftUI
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum ImmediateRoute: String, Route, Codable {
    case first, second, third
}

@MainActor
private final class ImmediateEventLog {
    var events: [String] = []
    var requests = 0

    func record(_ event: RouterEvent<ImmediateRoute>) {
        switch event {
        case .started: events.append("started")
        case .committed: events.append("committed")
        case .rejected: events.append("rejected")
        case .unchanged: events.append("unchanged")
        case .policyPrepared: events.append("policyPrepared")
        case .deferred: events.append("deferred")
        case .platformAdapted: events.append("platformAdapted")
        }
    }
}

/// `RouterDispatchTiming.immediateWhenIdle` commits a fire-and-forget request
/// before the dispatching call returns, but only when the asynchronous
/// pipeline would never have suspended. Every other case keeps the 7.0 path.
@Suite("Immediate dispatch", .serialized)
@MainActor
struct RouterImmediateDispatchTests {
    private typealias R = ImmediateRoute

    private func makeStore(
        _ timing: RouterDispatchTiming,
        configure: (inout RouterStoreConfiguration<R>) -> Void = { _ in }
    ) throws -> (RouterStore<R>, RouterActions<R>, ImmediateEventLog) {
        var configuration = RouterStoreConfiguration<R>()
        configuration.dispatchTiming = timing
        configure(&configuration)
        let store = try RouterStore<R>(configuration: configuration)
        let log = ImmediateEventLog()
        store.addSynchronousEventObserver { log.record($0) }
        store.addSynchronousRequestObserver { _ in log.requests += 1 }
        return (store, RouterActions(authority: RouterAuthority(scope: store.scope())), log)
    }

    @Test("The default timing commits on a later turn")
    func deferredIsDefault() async throws {
        let (store, router, log) = try makeStore(.deferred)
        #expect(RouterStoreConfiguration<R>().dispatchTiming == .deferred)

        let task = router.go(.first)
        #expect(store.state.root == .stack(path: []))
        #expect(log.events.isEmpty)

        guard case .applied = await task.value else {
            Issue.record("The deferred request did not apply")
            return
        }
        #expect(store.state.root == .stack(path: [.first]))
    }

    @Test("An idle Store commits before the dispatching call returns")
    func immediateCommit() async throws {
        let (store, router, log) = try makeStore(.immediateWhenIdle)

        let task = router.go(.first)
        #expect(store.state.root == .stack(path: [.first]))
        #expect(store.revision == 1)
        #expect(log.events == ["started", "committed"])
        #expect(log.requests == 1)

        // The returned task carries the same terminal outcome.
        guard case .applied(_, _, let after, let revision) = await task.value else {
            Issue.record("Expected the committed outcome")
            return
        }
        #expect(after.root == .stack(path: [.first]))
        #expect(revision == 1)
        // Nothing ran a second time on a later turn.
        #expect(store.revision == 1)
        #expect(log.events == ["started", "committed"])
    }

    @Test("A SwiftUI transaction wraps the state change itself")
    func commitInsideTransaction() throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)

        var committedInside = false
        withTransaction(Transaction(animation: .default)) {
            router.goMany([.first, .second])
            committedInside = store.state.root == .stack(path: [.first, .second])
        }
        #expect(committedInside)
    }

    @Test("Consecutive immediate requests each see the previous commit")
    func consecutiveRequests() throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)

        router.go(.first)
        router.go(.second)
        router.back()
        router.sheet(.third)

        guard case .stack(let stack) = store.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        #expect(stack.path == [.first])
        #expect(stack.presentation?.route == .third)
        #expect(store.revision == 4)
    }

    @Test("A rejected immediate request reports synchronously and changes nothing")
    func immediateRejection() async throws {
        let (store, router, log) = try makeStore(.immediateWhenIdle)
        router.sheet(.first)
        let before = store.state
        log.events.removeAll()

        // A stack cannot be pushed while its sheet is presented.
        let task = router.go(.second)
        #expect(log.events == ["rejected"])
        #expect(store.state == before)
        #expect(store.revision == 1)
        guard case .rejected(_, _, _, .mutation) = await task.value else {
            Issue.record("Expected a mutation rejection")
            return
        }
    }

    @Test("Root requests and transactions commit immediately")
    func rootRequests() throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)

        router.apply(RouterPlan(state: .rootStack(path: [.first])))
        #expect(store.state.root == .stack(path: [.first]))

        try router.transaction {
            RouterPlanStep.stack([.second, .third])
        }
        #expect(store.state.root == .stack(path: [.second, .third]))
        #expect(store.revision == 2)
    }

    @Test("A scoped router commits inside its own scope")
    func scopedRequest() throws {
        var configuration = RouterStoreConfiguration<R>()
        configuration.dispatchTiming = .immediateWhenIdle
        let store = try RouterStore<R>(
            initialState: try RouterState(root: .container(.init(
                style: .tabs, selection: "a", branches: [.init(id: "a"), .init(id: "b")]
            ))),
            configuration: configuration
        )
        let router = RouterActions(authority: RouterAuthority(scope: store.scope(at: ["b"])))

        router.go(.first)

        #expect(store.scope(at: ["b"]).node == .stack(path: [.first]))
        #expect(store.scope(at: ["a"]).node == .stack(path: []))
    }

    @Test("A Store with a prepare policy keeps the deferred pipeline")
    func policyKeepsDeferredPath() async throws {
        let (store, router, log) = try makeStore(.immediateWhenIdle) { configuration in
            configuration.policies = [RouterPolicy(name: "audit") { _ in .allow }]
        }

        let task = router.go(.first)
        #expect(store.state.root == .stack(path: []))
        #expect(log.events.isEmpty)

        guard case .applied = await task.value else {
            Issue.record("The policy-gated request did not apply")
            return
        }
        #expect(log.events == ["started", "policyPrepared", "committed"])
    }

    @Test("A Store with authorization keeps the deferred pipeline")
    func authorizationKeepsDeferredPath() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle) { configuration in
            configuration.authorization = .init(requiresAuthorization: { _ in true }, authorize: { true })
        }

        let task = router.go(.first)
        #expect(store.state.root == .stack(path: []))
        guard case .applied = await task.value else {
            Issue.record("The authorized request did not apply")
            return
        }
        #expect(store.state.root == .stack(path: [.first]))
    }

    @Test("A request made while another is committing keeps FIFO order on the deferred path")
    func reentrantRequestIsDeferred() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)
        let reentrant = TestCell<Task<RouterOutcome<R>, Never>?>(nil)
        let stateSeenByReentrantCall = TestCell<RouterNode<R>?>(nil)
        store.addSynchronousEventObserver { event in
            guard case .committed = event, reentrant.value == nil else { return }
            // The first request still owns the execution lane here.
            reentrant.value = router.go(.second)
            stateSeenByReentrantCall.value = store.state.root
        }

        router.go(.first)
        #expect(stateSeenByReentrantCall.value == .stack(path: [.first]))
        #expect(store.state.root == .stack(path: [.first]))

        guard case .applied = await (try #require(reentrant.value)).value else {
            Issue.record("The re-entrant request did not apply")
            return
        }
        #expect(store.state.root == .stack(path: [.first, .second]))
    }

    @Test("A cancelled calling task does not cancel the request")
    func cancelledCallerKeepsDeferredPath() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)

        let outcome = await Task { @MainActor () -> RouterOutcome<R> in
            withUnsafeCurrentTask { $0?.cancel() }
            let task = router.go(.first)
            // Running inline would inherit this cancellation and reject.
            #expect(store.state.root == .stack(path: []))
            return await task.value
        }.value

        guard case .applied = outcome else {
            Issue.record("The request inherited its caller's cancellation: \(outcome)")
            return
        }
        #expect(store.state.root == .stack(path: [.first]))
    }

    @Test("A transaction builds on the requests made before it", arguments: [
        RouterDispatchTiming.deferred, .immediateWhenIdle,
    ])
    func transactionFollowsEarlierRequests(timing: RouterDispatchTiming) async throws {
        let (store, router, _) = try makeStore(timing)

        router.go(.first)
        let transaction = try router.transaction {
            RouterPlanStep.presentation(.init(route: .second, style: .sheet))
        }

        guard case .applied = await transaction.value else {
            Issue.record("The transaction did not apply after an earlier request")
            return
        }
        // Neither request reverted or invalidated the other, in either timing.
        guard case .stack(let stack) = store.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        #expect(stack.path == [.first])
        #expect(stack.presentation?.route == .second)
        #expect(store.revision == 2)
    }

    @Test("A request dispatched inside a transaction builder is not reverted")
    func transactionBuilderSideEffectSurvives() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)

        // Evaluated while the builder runs, so the sheet commits first.
        func stepAfterPresentingSheet() -> RouterPlanStep<R> {
            router.sheet(.first)
            return .stack([.second])
        }
        let transaction = try router.transaction {
            stepAfterPresentingSheet()
        }
        let outcome = await transaction.value

        guard case .stack(let stack) = store.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        // The sheet committed while the builder ran. The transaction is then
        // derived from that state, so it either applies on top of the sheet
        // or is rejected; it never silently removes the sheet.
        #expect(stack.presentation?.route == .first, "The transaction dropped a commit made while it was built")
        if case .applied = outcome {
            #expect(stack.path == [.second])
        } else {
            #expect(stack.path.isEmpty)
            #expect(store.revision == 1)
        }
    }

    @Test("A system request dispatched earlier in the turn still runs first")
    func earlierDeferredDispatchKeepsItsPlace() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)
        router.sheet(.first)
        #expect(store.revision == 1)

        // What a sheet binding's setter does when SwiftUI dismisses the sheet.
        let dismissal = store.scope().dispatch(.dismissPresentation, context: .init(source: .system))
        // Made later in the same turn: it must not overtake the dismissal,
        // or the push is rejected under the sheet that is about to go away.
        let push = router.go(.second)
        #expect(store.revision == 1, "The later request committed ahead of the earlier one")

        guard case .applied = await dismissal.value, case .applied = await push.value else {
            Issue.record("A request was lost to reordering")
            return
        }
        #expect(store.state.root == .stack(path: [.second]))
    }

    @Test("Requests keep call order across a re-entrant fallback")
    func callOrderSurvivesReentrantFallback() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)
        let reentrant = TestCell<Task<RouterOutcome<R>, Never>?>(nil)
        store.addSynchronousEventObserver { event in
            guard case .committed = event, reentrant.value == nil else { return }
            reentrant.value = router.go(.second)
        }

        router.go(.first)
        let third = router.go(.third)

        _ = await (try #require(reentrant.value)).value
        _ = await third.value
        #expect(store.state.root == .stack(path: [.first, .second, .third]))
    }

    @Test("Cancelling an awaited presentation, then navigating, keeps that order", arguments: [
        RouterDispatchTiming.deferred, .immediateWhenIdle,
    ])
    func cancelledPresentationDismissesFirst(timing: RouterDispatchTiming) async throws {
        let (store, router, _) = try makeStore(timing)
        let presenting = Task { @MainActor in
            await router.present(.second, style: .sheet, expecting: Int.self)
        }
        try await waitUntil("the sheet is presented") {
            if case .stack(let stack) = store.state.root { return stack.presentation != nil }
            return false
        }

        // One handler: cancel the presentation, then navigate.
        presenting.cancel()
        let push = router.go(.third)

        guard case .applied = await push.value else {
            Issue.record("The push overtook the dismissal and was rejected under the sheet")
            return
        }
        _ = await presenting.value
        #expect(store.state.root == .stack(path: [.third]))
    }

    @Test("Every public entry point that defers is counted until it starts")
    func deferredEntryPointsHoldTheGate() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)
        let scope = store.scope()

        let tasks = [
            store.dispatch(.push(.first)),
            scope.dispatch(.push(.second)),
            scope.dispatchRoot(.push(.third)),
        ]
        #expect(store.dispatchGate.unstartedDispatches == 3)
        let last = router.goMany([.first, .second])
        #expect(store.revision == 0)

        for task in tasks { _ = await task.value }
        _ = await last.value
        #expect(store.dispatchGate.unstartedDispatches == 0)
        #expect(store.state.root == .stack(path: [.first, .second, .third, .first, .second]))

        // With nothing pending the next request is immediate again.
        router.back()
        #expect(store.state.root == .stack(path: [.first, .second, .third, .first]))
    }

    @Test("A request made from an event handler waits for that event to be delivered")
    func eventHandlerRequestDoesNotRunInsideTheEvent() async throws {
        let handled = TestCell<Task<RouterOutcome<R>, Never>?>(nil)
        let routerBox = TestCell<RouterActions<R>?>(nil)
        let (store, router, log) = try makeStore(.immediateWhenIdle) { configuration in
            // `onEvent` runs before the synchronous observers that fill `log`.
            configuration.onEvent = { event in
                guard case .rejected = event, handled.value == nil else { return }
                handled.value = routerBox.value?.go(.first)
            }
        }
        routerBox.value = router

        // Rejected with the lane free, so the handler runs while idle.
        _ = store.rejectRequest(reason: .cancelled)
        #expect(log.events == ["rejected"])
        #expect(store.revision == 0)

        guard case .applied = await (try #require(handled.value)).value else {
            Issue.record("The handler's request did not apply")
            return
        }
        #expect(log.events == ["rejected", "started", "committed"])
    }

    @Test("Cancelling the caller while its request commits does not cancel the request")
    func callerCancelledMidCommit() async throws {
        let (store, router, _) = try makeStore(.immediateWhenIdle)
        let caller = TestCell<Task<RouterOutcome<R>, Never>?>(nil)
        // Runs inside the immediate commit, on the caller's own task.
        store.addSynchronousRequestObserver { _ in caller.value?.cancel() }

        let task = Task { @MainActor () -> RouterOutcome<R> in await router.go(.first).value }
        caller.value = task
        guard case .applied = await task.value else {
            Issue.record("The request inherited a cancellation that arrived mid-commit")
            return
        }
        #expect(store.state.root == .stack(path: [.first]))
        #expect(store.dispatchGate.ignoresTaskCancellation == false)
    }
}
