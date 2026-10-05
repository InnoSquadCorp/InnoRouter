import Foundation
import Observation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Store frozen host contract admission", .timeLimit(.minutes(1)))
@MainActor
struct RouterStoreHostContractTests {
    private enum R: String, Route, Codable { case home, detail }
    private var stack: RouterHostDescriptor<R> { .init(root: .stack) }
    private func tabDescriptor(_ extras: RouterHostOrphanPolicy = .reject) -> RouterHostDescriptor<R> {
        .init(root: .tabs(branches: [.init("left", shape: .stack), .init("right", shape: .stack)], extras: extras))
    }
    private func tabs(extra: Bool = false) throws -> RouterState<R> {
        var branches = [RouterBranch<R>(id: "left"), RouterBranch<R>(id: "right")]
        if extra { branches.append(.init(id: "legacy", node: .stack(path: [.home]))) }
        return try .init(root: .container(.init(style: .tabs, selection: "left", branches: branches)))
    }
    private func expectHostRejection(_ outcome: RouterOutcome<R>, _ code: RouterHostValidationFailure.Code) {
        guard case .rejected(_, _, _, .hostContract(let failure)) = outcome else {
            Issue.record("Expected typed host rejection"); return
        }
        #expect(failure.code == code)
    }

    @Test("The default native stack convenience has an admitted fixed descriptor")
    func safeDefaultHost() throws {
        let store = RouterStore<R>.makeDefaultHostedStack()
        try store.validateHostRenderer(shape: .stack, at: .root, rootDeclarations: [
            .init(path: [], meaning: .declarationID("router.root")),
        ])
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Creation validates the whole state and supplied hosts require a contract")
    func creationAndRendererAdmission() throws {
        #expect(throws: RouterHostValidationFailure.self) {
            try RouterStore(initialState: tabs(), configuration: .init(hostDescriptor: stack))
        }
        let unhosted = RouterStore<R>()
        #expect(throws: RouterHostValidationFailure.self) {
            try unhosted.validateHostRenderer(shape: .stack, at: .root)
        }
        let hosted = try RouterStore(initialState: tabs(), configuration: .init(hostDescriptor: tabDescriptor()))
        try hosted.validateHostRenderer(shape: tabDescriptor().root, at: .root)
        try hosted.validateHostRenderer(shape: .stack, at: ["left"])
        #expect(throws: RouterHostValidationFailure.self) {
            try hosted.validateHostRenderer(shape: .stack, at: .root)
        }
        #expect(hosted.revision == 0)
    }

    @Test("Ordinary apply rejects topology drift before policy and preserves state and descriptor")
    func applyDoesNotChangeHost() async throws {
        let calls = Mutex(0)
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack, policies: [
            .init(name: "count") { _ in calls.withLock { $0 += 1 }; return .allow },
        ]))
        let before = store.committedValue.hostGeneration
        expectHostRejection(await store.perform(.apply(.init(state: try tabs()))), .kindMismatch)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.committedValue.hostGeneration == before)
        #expect(calls.withLock { $0 } == 0)
        guard case .applied = await store.perform(.push(.detail)) else { Issue.record("Valid stack control"); return }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Dormant orphan preservation is explicit, retains contents, and blocks orphan selection")
    func explicitOrphanPreservation() async throws {
        let target = try tabs(extra: true)
        #expect(throws: RouterHostValidationFailure.self) {
            try RouterStore(initialState: target, configuration: .init(hostDescriptor: tabDescriptor()))
        }
        let store = try RouterStore(initialState: target, configuration: .init(hostDescriptor: tabDescriptor(.preserveDormant)))
        #expect(store.state == target)
        expectHostRejection(await store.perform(.select("legacy")), .selectionNotRendered)
        #expect(store.state.node(at: ["legacy"]) == .stack(path: [.home]))
        guard case .applied = await store.perform(.select("right")) else { Issue.record("Declared selection control"); return }
    }

    @Test("Host replacement commits one matching observable pair and revision")
    func atomicObservation() async throws {
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack))
        let target = try tabs()
        let notifications = Mutex(0), mismatches = Mutex(0)
        withObservationTracking {
            _ = store.state
            _ = store.hostDescriptor
        } onChange: {
            notifications.withLock { $0 += 1 }
            MainActor.assumeIsolated {
                do { try store.hostDescriptor?.validate(store.state, resourceBudget: store.resourceBudget) }
                catch { mismatches.withLock { $0 += 1 } }
            }
        }
        guard case .applied = await store.replaceHost(with: .init(state: target), descriptor: tabDescriptor()) else {
            Issue.record("Valid owner replacement must commit"); return
        }
        #expect(notifications.withLock { $0 } == 1)
        #expect(mismatches.withLock { $0 } == 0)
        #expect(store.state == target)
        #expect(store.revision == 1)
        try store.validateHostRenderer(shape: tabDescriptor().root, at: .root)
    }

    @Test("Same-ID equal graph replacement still retires renderer and child ownership")
    func equalReplacementRetiresAuthority() async throws {
        let store = try RouterStore(initialState: tabs(), configuration: .init(hostDescriptor: tabDescriptor()))
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        let oldGeneration = store.committedValue.hostGeneration
        guard case .applied = await store.replaceHost(with: .init(state: store.state), descriptor: tabDescriptor()) else {
            Issue.record("Host meaning replacement is a real commit even for equal state"); return
        }
        #expect(store.revision == 1)
        #expect(store.committedValue.hostGeneration != oldGeneration)
        #expect(left.node == nil)
        #expect(right.node == nil)
        #expect(store.scope(at: ["left"]).node != nil)
        guard case .rejected(_, _, _, .mutation(.expiredScope)) = await left.perform(.push(.detail)) else {
            Issue.record("An old renderer callback must not acquire the new same-ID branch"); return
        }
        guard case .applied = await store.scope(at: ["left"]).perform(.push(.detail)) else {
            Issue.record("The replacement renderer must retain normal navigation"); return
        }
    }

    @Test("Policy rejection leaves the descriptor and graph unchanged")
    func rejectedReplacementIsAtomic() async throws {
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack, policies: [
            .init(name: "deny") { _ in .reject("blocked") },
        ]))
        let generation = store.committedValue.hostGeneration
        guard case .rejected(_, _, _, .policy) = await store.replaceHost(with: .init(state: try tabs()), descriptor: tabDescriptor()) else {
            Issue.record("Replacement must honor policy"); return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.committedValue.hostGeneration == generation)
        try store.validateHostRenderer(shape: .stack, at: .root)
    }

    @Test("A deferred replacement carries its descriptor through ordinary state rebase")
    func deferredReplacementRebase() async throws {
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack, policies: [
            .init(name: "hold") { transition in
                if case .apply = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(id) }
                return .allow
            },
        ]))
        guard case .deferred = await store.replaceHost(with: .init(state: try tabs()), descriptor: tabDescriptor()) else {
            Issue.record("Expected deferred replacement"); return
        }
        try store.validateHostRenderer(shape: .stack, at: .root)
        _ = await store.perform(.push(.home))
        guard case .applied = await store.resumeDeferred(id, strategy: .rebaseOnCurrentState) else {
            Issue.record("Descriptor must survive resume"); return
        }
        #expect(store.revision == 2)
        try store.validateHostRenderer(shape: tabDescriptor().root, at: .root)
    }

    @Test("Rebasing an old deferred request cannot acquire a replacement host generation")
    func staleDeferredRequest() async throws {
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack, policies: [
            .init(name: "hold-push") { transition in
                if case .push = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(id) }
                return .allow
            },
        ]))
        guard case .deferred = await store.perform(.push(.home)) else { Issue.record("Expected deferral"); return }
        _ = await store.replaceHost(with: .init(state: .rootStack), descriptor: stack)
        expectHostRejection(await store.resumeDeferred(id, strategy: .rebaseOnCurrentState), .stale)
        #expect(store.state == .rootStack)
        #expect(store.revision == 1)
    }

    @Test("Unrelated incremental changes preserve host generation and sibling scope")
    func ordinaryIncrementalControl() async throws {
        let store = try RouterStore(initialState: tabs(), configuration: .init(hostDescriptor: tabDescriptor()))
        let right = store.scope(at: ["right"]), generation = store.committedValue.hostGeneration
        _ = await store.scope(at: ["left"]).perform(.push(.detail))
        _ = await store.perform(.select("right"))
        #expect(right === store.scope(at: ["right"]))
        #expect(store.committedValue.hostGeneration == generation)
        #expect(store.revision == 2)
    }
    private actor Gate {
        nonisolated let entered: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        private var waiter: CheckedContinuation<Void, Never>?
        init() { (entered, signal) = AsyncStream<Void>.makeStream() }
        func wait() async {
            await withCheckedContinuation { continuation in
                waiter = continuation
                signal.yield(())
            }
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    @Test("A request queued before host replacement cannot run in its new incarnation")
    func staleQueuedRequest() async throws {
        let gate = Gate()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        defer { queuedSignal.finish() }
        var configuration = RouterStoreConfiguration<R>(hostDescriptor: stack, policies: [
            .init(name: "hold") { transition in
                if case .apply = transition.action { await gate.wait() }
                return .allow
            },
        ])
        configuration.runtimeDependencies.didQueueRequest = { _ in queuedSignal.yield(()) }
        let store = try RouterStore<R>(configuration: configuration)
        let descriptor = stack
        let replacement = Task { await store.replaceHost(with: .init(state: .rootStack), descriptor: descriptor) }
        var entered = gate.entered.makeAsyncIterator()
        _ = await entered.next()
        let stale = Task { await store.perform(.push(.detail)) }
        var waiting = queued.makeAsyncIterator()
        _ = await waiting.next()
        await gate.release()
        guard case .applied = await replacement.value else { Issue.record("Replacement control failed"); return }
        expectHostRejection(await stale.value, .stale)
        #expect(store.state == .rootStack)
        #expect(store.revision == 1)
    }

    @Test("Cancellation during host policy preparation retains both original values")
    func cancelledReplacement() async throws {
        let gate = Gate()
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack, policies: [
            .init(name: "hold") { _ in await gate.wait(); return .allow },
        ]))
        let generation = store.committedValue.hostGeneration
        let target = try tabs(), descriptor = tabDescriptor()
        let task = Task { await store.replaceHost(with: .init(state: target), descriptor: descriptor) }
        var entered = gate.entered.makeAsyncIterator()
        _ = await entered.next()
        task.cancel()
        await gate.release()
        guard case .rejected(_, _, _, .cancelled) = await task.value else { Issue.record("Cancellation must reject"); return }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.committedValue.hostGeneration == generation)
    }

    @Test("Snapshot decoding still converges on host admission")
    func restoredTopologyMismatch() async throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: stack))
        let incompatible = try codec.encode(tabs())
        expectHostRejection(try await store.restore(from: incompatible, using: codec), .kindMismatch)
        #expect(store.state == .rootStack)
        let compatible = try codec.encode(.rootStack(path: [.home]))
        guard case .applied = try await store.restore(from: compatible, using: codec) else {
            Issue.record("Matching snapshot positive control failed"); return
        }
        #expect(store.revision == 1)
    }
}
