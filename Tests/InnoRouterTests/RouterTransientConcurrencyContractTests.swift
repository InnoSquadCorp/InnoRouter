import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Typed presentation concurrent ownership", .timeLimit(.minutes(1)))
@MainActor
struct RouterTransientConcurrencyContractTests {
    private enum R: Route { case child }
    private var request: RouterTransientPresentationRequest<Int> {
        .alert(title: "T", actions: [.init(id: "accept", label: "A", value: 42)])
    }

    @Test("A reusable request owns distinct scopes independently but cannot replace an occupied scope")
    func simultaneousReuse() async throws {
        let store = try RouterStore<R>(initialState: .init(root: .container(.init(style: .tabs, selection: "left", branches: [
            .init(id: "left"), .init(id: "right"),
        ]))))
        var events = store.events.makeAsyncIterator()
        let declaration = request
        let left = Task { @MainActor in await store.present(declaration, at: ["left"]) }
        let right = Task { @MainActor in await store.present(declaration, at: ["right"]) }
        defer { left.cancel(); right.cancel() }
        var commits = 0
        while let event = await events.next() {
            if case .committed = event { commits += 1 }
            if commits == 2 { break }
        }
        let leftHandle = try #require(store.presentationHandle(at: ["left"]))
        let rightHandle = try #require(store.presentationHandle(at: ["right"]))
        #expect(leftHandle.id != rightHandle.id)
        guard case .rejected = await store.present(declaration, at: ["left"]) else { Issue.record("Occupied scope accepted another show"); return }
        #expect(store.presentationWaiters.count == 2)
        _ = await store.selectPresentationAction("accept", using: rightHandle)
        #expect(await right.value == .value(42))
        #expect(store.presentationWaiters.count == 1)
        _ = await store.dismissPresentation(using: leftHandle)
        #expect(await left.value == .dismissed)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
    }

    @Test("Cancelling a deferred show retires its waiter and request family", arguments: [false, true])
    func cancelledDeferredShow(navigation: Bool) async throws {
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [.init(name: "hold") { _ in .deferRequest(id) }]))
        var events = store.events.makeAsyncIterator()
        let task = Task { @MainActor in
            if navigation { return await store.present(.child, expecting: Int.self) }
            return await store.present(request)
        }
        while let event = await events.next() { if case .deferred = event { break } }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("A generation change while showing is deferred cannot silently reauthorize its waiter", arguments: [false, true])
    func deferredShowEpoch(navigation: Bool) async throws {
        let epoch = Epoch(), id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(
            policies: [.init(name: "hold") { transition in transition.context.resumedDeferral == nil ? .deferRequest(id) : .allow }],
            authorization: .init(generation: { epoch.value }, requiresAuthorization: { _ in false }, authorize: { true })
        ))
        var events = store.events.makeAsyncIterator()
        let task = Task { @MainActor in
            if navigation { return await store.present(.child, expecting: Int.self) }
            return await store.present(request)
        }
        defer { task.cancel() }
        while let event = await events.next() { if case .deferred = event { break } }
        epoch.value += 1
        _ = await store.resumeDeferred(id)
        guard case .rejected(.authorization(let failure)) = await task.value else { Issue.record("Changed generation acquired show authority"); return }
        #expect(failure.code == .generationChanged)
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("Caller cancellation while a show is queued or policy-suspended cannot publish UI", arguments: [false, true], [false, true])
    func cancelledPendingShow(queued: Bool, navigation: Bool) async throws {
        let gate = Gate()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold") { transition in
                let blocks: Bool
                switch transition.action {
                case .push: blocks = queued
                case .present, .presentAlert: blocks = !queued
                default: blocks = false
                }
                if blocks { await gate.wait() }
                return .allow
            },
        ]))
        let blocker: Task<RouterOutcome<R>, Never>? = queued ? Task { @MainActor in await store.perform(.push(.child)) } : nil
        if queued { while !gate.entered { await Task.yield() } }
        let show = Task { @MainActor in
            if navigation { return await store.present(.child, expecting: Int.self) }
            return await store.present(request)
        }
        if queued { while store.queuedRequests.isEmpty { await Task.yield() } }
        else { while !gate.entered { await Task.yield() } }
        show.cancel()
        gate.release()
        #expect(await show.value == .cancelled)
        _ = await blocker?.value
        #expect(store.presentationHandle() == nil)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
        #expect(store.queuedRequests.isEmpty)
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.revision == (queued ? 1 : 0))
    }

    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor private final class Epoch { var value: UInt64 = 0 }
}
