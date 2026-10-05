import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Typed transient presentation lifetime", .timeLimit(.minutes(1)))
@MainActor
struct RouterTransientPresentationLifetimeTests {
    private enum R: String, Route, Codable { case parent, child }
    private enum Choice: Sendable, Equatable { case accept, cancel }

    private func request(dialog: Bool = false) -> RouterTransientPresentationRequest<Choice> {
        .init(kind: dialog ? .confirmationDialog : .alert, title: "Title", message: "Message", actions: [
            .init(id: "accept", label: "Accept", role: .destructive, value: .accept),
            .init(id: "cancel", label: "Cancel", role: .cancel, value: .cancel),
        ])
    }

    private func open<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>, in store: RouterStore<R>
    ) async throws -> (Task<RouterPresentationOutcome<Value>, Never>, RouterPresentationHandle) {
        var events = store.events.makeAsyncIterator()
        let task = Task { @MainActor in await store.present(request) }
        while let event = await events.next() { if case .committed = event { break } }
        do { return (task, try #require(store.presentationHandle())) }
        catch { task.cancel(); throw error }
    }

    private func reject(_ outcome: RouterOutcome<R>, _ expected: RouterRejectionReason) {
        guard case .rejected(_, _, _, let reason) = outcome else { Issue.record("Expected rejection"); return }
        #expect(reason == expected)
    }

    @Test("Each declared button returns its exact value, including cancel-role buttons", arguments: [false, true], [false, true])
    func typedSelection(dialog: Bool, cancel: Bool) async throws {
        let store = RouterStore<R>()
        let (task, handle) = try await open(request(dialog: dialog), in: store)
        #expect(store.scope().presentationFamily?.id == handle.id)
        #expect(store.state.node(at: .root.appendingPresentation(handle.id)) == nil)
        _ = await store.selectPresentationAction(cancel ? "cancel" : "accept", using: handle)
        #expect(await task.value == .value(cancel ? .cancel : .accept))
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
        #expect(store.revision == 2)
    }

    @Test("Raw Store selection uses the same typed result pipeline")
    func rawSelection() async throws {
        let store = RouterStore<R>()
        let (task, handle) = try await open(request(), in: store)
        _ = await store.perform(.selectPresentationAction(presentationID: handle.id, actionID: "accept"))
        #expect(await task.value == .value(.accept))
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Descriptor-only selection creates no typed waiter")
    func descriptorOnly() async {
        let store = RouterStore<R>()
        let descriptor = RouterTransientPresentation(content: .init(title: "Title", actions: [.init(id: "a", label: "A")]))
        _ = await store.perform(.presentAlert(descriptor))
        #expect(store.presentationWaiters.isEmpty)
        _ = await store.perform(.selectPresentationAction(presentationID: descriptor.id, actionID: "a"))
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Unknown button and generic navigation completion cannot inject a value")
    func declaredValuesOnly() async throws {
        let store = RouterStore<R>()
        let (task, handle) = try await open(request(), in: store)
        let state = store.state
        reject(await store.selectPresentationAction("unknown", using: handle), .mutation(.unknownPresentationAction(.root)))
        await #expect(throws: RouterPresentationCompletionError.dismissalRejected(.mutation(.expectedNavigationPresentation(.root)))) {
            try await store.finishPresentation(returning: Choice.accept)
        }
        #expect(store.state == state)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.count == 1)
        _ = await store.dismissPresentation(using: handle)
        #expect(await task.value == .dismissed)
    }

    @Test("Ordinary dismissal and caller cancellation have distinct terminal values", arguments: [false, true])
    func dismissOrCancel(cancel: Bool) async throws {
        let store = RouterStore<R>()
        let (task, handle) = try await open(request(), in: store)
        if cancel { task.cancel() }
        else { _ = await store.dismissPresentation(using: handle) }
        #expect(await task.value == (cancel ? .cancelled : .dismissed))
        // Caller cancellation publishes its result before optional policy-bound
        // cleanup completes. Drain the serialized lane explicitly.
        _ = await store.perform(.dismissPresentation)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
        #expect(store.state == .rootStack)
    }

    @Test("Repeated request reuse gets new identities and releases cancellation state")
    func repeatedCancellation() async throws {
        let store = RouterStore<R>(), declaration = request()
        var ids = Set<UUID>()
        for _ in 0..<24 {
            let (task, handle) = try await open(declaration, in: store)
            #expect(ids.insert(handle.id).inserted)
            task.cancel()
            #expect(await task.value == .cancelled)
            _ = await store.perform(.dismissPresentation)
            #expect(store.presentationWaiters.isEmpty)
            #expect(store.presentationRequestIDs.isEmpty)
            #expect(store.deferredTransitions.isEmpty)
        }
        #expect(ids.count == 24)
    }

    @Test("Rejecting one selection clears only its own preparation and permits a different value")
    func rejectedSelection() async throws {
        let deny = Mutex(true)
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "choose") { transition in
                if case .selectPresentationAction = transition.action, deny.withLock({ $0 }) { return .reject("denied") }
                return .allow
            },
        ]))
        let (task, handle) = try await open(request(), in: store)
        let state = store.state
        reject(await store.selectPresentationAction("accept", using: handle), .policy(name: "choose", message: "denied"))
        #expect(store.state == state)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.count == 1)
        deny.withLock { $0 = false }
        _ = await store.selectPresentationAction("cancel", using: handle)
        #expect(await task.value == .value(.cancel))
    }

    @Test("Repeated deferral may reuse a logical ID without losing the private prepared result")
    func repeatedDeferral() async throws {
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "first") { if case .selectPresentationAction = $0.action { return .deferRequest(id) }; return .allow },
            .init(name: "second") { if case .selectPresentationAction = $0.action { return .deferRequest(id) }; return .allow },
        ]))
        let (task, handle) = try await open(request(), in: store)
        guard case .deferred = await store.selectPresentationAction("accept", using: handle) else { Issue.record("Expected deferral"); task.cancel(); return }
        let state = store.state
        reject(await store.selectPresentationAction("cancel", using: handle), .mutation(.presentationCompletionPending(handle.id)))
        reject(await store.perform(.selectPresentationAction(presentationID: handle.id, actionID: "accept"), context: .init(resumedDeferral: id)), .mutation(.presentationCompletionPending(handle.id)))
        #expect(store.state == state)
        #expect(store.revision == 1)
        guard case .deferred = await store.resumeDeferred(id) else { Issue.record("Expected second deferral"); task.cancel(); return }
        #expect(store.presentationWaiters.count == 1)
        #expect(store.revision == 1)
        _ = await store.resumeDeferred(id)
        #expect(await task.value == .value(.accept))
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Cancelling a deferred selection retains the UI but releases its prepared value")
    func cancelledSelectionDeferral() async throws {
        let id = RouterDeferralID(), hold = Mutex(true)
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold") { transition in
                if case .selectPresentationAction = transition.action, hold.withLock({ $0 }) { return .deferRequest(id) }
                return .allow
            },
        ]))
        let (task, handle) = try await open(request(), in: store)
        _ = await store.selectPresentationAction("accept", using: handle)
        _ = await store.cancelDeferred(id)
        #expect(store.presentationWaiters.count == 1)
        #expect(store.revision == 1)
        hold.withLock { $0 = false }
        _ = await store.selectPresentationAction("cancel", using: handle)
        #expect(await task.value == .value(.cancel))
    }

    @Test("Replacing the same logical transient cancels its old waiter and expires its handle")
    func sameIDReplacement() async throws {
        let store = RouterStore<R>()
        let (task, handle) = try await open(request(), in: store)
        let original = store.state
        _ = await store.replaceSubtree(with: original.root)
        #expect(await task.value == .cancelled)
        #expect(store.state == original)
        #expect(store.revision == 1)
        reject(await store.selectPresentationAction("accept", using: handle), .mutation(.expiredPresentation(handle.id, scope: .root)))
        let replacement = try #require(store.presentationHandle())
        #expect(replacement != handle)
        _ = await store.selectPresentationAction("accept", using: replacement)
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Parent removal cancels a child alert instead of claiming an independent dismissal")
    func parentRemoval() async throws {
        let store = RouterStore<R>()
        let parentID = UUID()
        _ = await store.perform(.present(.init(id: parentID, route: .parent, style: .sheet)))
        let scope = store.scope(at: .root.appendingPresentation(parentID))
        var events = store.events.makeAsyncIterator()
        let task = Task { @MainActor in await scope.present(request()) }
        while let event = await events.next() { if case .committed = event { break } }
        let child = try #require(scope.presentationHandle())
        _ = await store.perform(.dismissPresentation)
        #expect(await task.value == .cancelled)
        #expect(store.presentationWaiters.isEmpty)
        guard case .rejected = await scope.selectPresentationAction("accept", using: child) else { Issue.record("Expired scope accepted callback"); return }
        #expect(store.state == .rootStack)
    }

    @Test("A Value needs no Hashable or Codable conformance and is never invoked by the router")
    func opaqueValues() async throws {
        struct Value: Sendable { let run: @Sendable () -> Int }
        let calls = Mutex(0)
        let store = RouterStore<R>()
        let declaration = RouterTransientPresentationRequest<Value>.alert(title: "Title", actions: [
            .init(id: "run", label: "Run", value: .init(run: { calls.withLock { $0 += 1 }; return 42 })),
        ])
        let (task, handle) = try await open(declaration, in: store)
        _ = await store.selectPresentationAction("run", using: handle)
        #expect(calls.withLock { $0 } == 0)
        guard case .value(let value) = await task.value else { Issue.record("Expected opaque value"); return }
        #expect(calls.withLock { $0 } == 0)
        #expect(value.run() == 42)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Oversized and invalid declarations reject before waiter or policy creation")
    func requestAdmission() async throws {
        let calls = Mutex(0)
        let store = try RouterStore<R>(configuration: .init(resourceBudget: .init(snapshot: .init(maximumPayloadBytes: 3)), policies: [
            .init(name: "count") { _ in calls.withLock { $0 += 1 }; return .allow },
        ]))
        guard case .rejected(.resourceLimit) = await store.present(request()) else { Issue.record("Expected metadata rejection"); return }
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
        #expect(calls.withLock { $0 } == 0)
        #expect(store.revision == 0)
        let empty = RouterTransientPresentationRequest<Int>.alert(title: "", actions: [])
        guard case .rejected(.mutation(.invalidTargetState(.invalidTransientPresentation(.emptyActions)))) = await store.present(empty) else {
            Issue.record("Expected declaration rejection"); return
        }
        #expect(store.presentationWaiters.isEmpty)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("Snapshot omission neither mutates live UI nor resolves its result waiter")
    func liveSnapshotOmission() async throws {
        let store = RouterStore<R>()
        let (task, handle) = try await open(request(), in: store)
        let original = store.state
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1, transientPresentations: .omit)
        #expect(try codec.decode(codec.encode(store.state)) == .rootStack)
        #expect(store.state == original)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.count == 1)
        _ = await store.selectPresentationAction("accept", using: handle)
        #expect(await task.value == .value(.accept))
    }

    @Test("Runtime typed requests are explicitly marked as incomplete replay authority")
    func runtimeReplayLimitation() async throws {
        let store = RouterStore<R>()
        var requests = store.requestObservations.makeAsyncIterator()
        let (task, handle) = try await open(request(), in: store)
        let show = try #require(await requests.next())
        #expect(show.replayLimitationCode == "presentation.runtimeResultAuthority")
        _ = await store.selectPresentationAction("accept", using: handle)
        let selection = try #require(await requests.next())
        #expect(selection.replayLimitationCode == "presentation.runtimeResultAuthority")
        #expect(await task.value == .value(.accept))
    }
}
