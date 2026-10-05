import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Presentation result authorization continuity", .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationResultAuthorizationTests {
    private enum R: Route { case child }

    @MainActor
    private final class Session {
        var epoch: UInt64 = 0
        func configuration(tracksEpoch: Bool = true) -> RouterAuthorizationConfiguration<R> {
            let provider: (@MainActor @Sendable () -> UInt64)? = tracksEpoch ? { @MainActor @Sendable in self.epoch } : nil
            return .init(generation: provider, requiresAuthorization: { _ in false }, authorize: { true })
        }
    }

    private func request() -> RouterTransientPresentationRequest<String> {
        .alert(title: "Title", actions: [.init(id: "accept", label: "Accept", value: "result")])
    }

    private func open(_ store: RouterStore<R>) async throws -> (Task<RouterPresentationOutcome<String>, Never>, RouterPresentationHandle) {
        var events = store.events.makeAsyncIterator()
        let task = Task { @MainActor in await store.present(request()) }
        while let event = await events.next() { if case .committed = event { break } }
        do { return (task, try #require(store.presentationHandle())) }
        catch { task.cancel(); throw error }
    }

    private func generationChanged(_ outcome: RouterOutcome<R>) {
        guard case .rejected(_, _, _, .authorization(let failure)) = outcome else {
            Issue.record("Expected original authorization generation rejection"); return
        }
        #expect(failure.code == .generationChanged)
    }

    @Test("An epoch change before responding cannot acquire a new account's result authority")
    func changedBeforeResponse() async throws {
        let session = Session(), policies = Mutex(0)
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "count") { _ in policies.withLock { $0 += 1 }; return .allow },
        ], authorization: session.configuration()))
        let (task, handle) = try await open(store)
        let original = store.state
        policies.withLock { $0 = 0 }
        session.epoch += 1
        generationChanged(await store.selectPresentationAction("accept", using: handle))
        #expect(policies.withLock { $0 } == 0)
        #expect(store.state == original)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.count == 1)
        _ = await store.dismissPresentation(using: handle)
        #expect(await task.value == .dismissed)
        let (fresh, freshHandle) = try await open(store)
        _ = await store.selectPresentationAction("accept", using: freshHandle)
        #expect(await fresh.value == .value("result"))
    }

    @Test("An epoch change during policy suspension rejects before commit and value delivery")
    func changedDuringPolicy() async throws {
        let session = Session(), gate = PresentationResultPolicyGate()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "suspend") { transition in
                if case .selectPresentationAction = transition.action { await gate.wait() }
                return .allow
            },
        ], authorization: session.configuration()))
        let (task, handle) = try await open(store)
        let original = store.state
        let selected = Task { @MainActor in await store.selectPresentationAction("accept", using: handle) }
        while !gate.entered { await Task.yield() }
        session.epoch += 1
        gate.release()
        generationChanged(await selected.value)
        #expect(store.state == original)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.count == 1)
        _ = await store.dismissPresentation(using: handle)
        #expect(await task.value == .dismissed)
    }

    @Test("A deferred selection retains the show-time epoch until its real resumption")
    func changedAcrossDeferral() async throws {
        let session = Session(), id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold") { if case .selectPresentationAction = $0.action { return .deferRequest(id) }; return .allow },
        ], authorization: session.configuration()))
        let (task, handle) = try await open(store)
        let original = store.state
        guard case .deferred = await store.selectPresentationAction("accept", using: handle) else {
            Issue.record("Expected deferral"); task.cancel(); return
        }
        session.epoch += 1
        generationChanged(await store.resumeDeferred(id, strategy: .rebaseOnCurrentState))
        #expect(store.state == original)
        #expect(store.revision == 1)
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.presentationWaiters.count == 1)
        _ = await store.dismissPresentation(using: handle)
        #expect(await task.value == .dismissed)
    }

    @Test("Navigation result waiters use the same show-to-finish authorization contract")
    func navigationResultEpoch() async throws {
        let session = Session()
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await store.present(.child, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        let original = store.state
        session.epoch += 1
        await #expect(throws: RouterPresentationCompletionError.dismissalRejected(.authorization(.init(code: .generationChanged)))) {
            try await store.finishPresentation(returning: "old-result")
        }
        #expect(store.state == original)
        #expect(store.revision == 1)
        _ = await store.perform(.dismissPresentation)
        #expect(await result.value == .dismissed)
    }

    @Test("An unchanged generation allows the selected value")
    func unchangedEpochControl() async throws {
        let session = Session()
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        let (task, handle) = try await open(store)
        _ = await store.selectPresentationAction("accept", using: handle)
        #expect(await task.value == .value("result"))
    }

    @Test("Without a generation provider the router cannot infer an application session change")
    func noProviderControl() async throws {
        let session = Session()
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration(tracksEpoch: false)))
        let (task, handle) = try await open(store)
        session.epoch += 1
        _ = await store.selectPresentationAction("accept", using: handle)
        #expect(await task.value == .value("result"))
    }
}

@MainActor
private final class PresentationResultPolicyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
