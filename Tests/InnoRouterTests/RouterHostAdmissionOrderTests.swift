import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum HostAdmissionSceneRoute: Route, RouterSceneRoute {
    case window

    static let sceneLookups = Mutex(0)
    static var routerScenes: [RouterSceneDescriptor<Self>] {
        sceneLookups.withLock { $0 += 1 }
        return [.init(route: .window, id: "window", style: .window)]
    }
}

private final class HostAdmissionResolverGate: Sendable {
    let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let calls = Mutex(0)
    private let didTimeOut = Mutex(false)

    init() { (entered, signal) = AsyncStream<Void>.makeStream() }

    func resolve() -> String {
        let count = calls.withLock { value in value += 1; return value }
        if count == 3 {
            signal.yield(())
            if releaseSignal.wait(timeout: .now() + 20) == .timedOut {
                didTimeOut.withLock { $0 = true }
            }
        }
        return "window"
    }

    func release() { releaseSignal.signal() }
    func finish() { release(); signal.finish() }
    var count: Int { calls.withLock { $0 } }
    var timedOut: Bool { didTimeOut.withLock { $0 } }
}

@Suite("Host admission precedes application scene callbacks", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterHostAdmissionOrderTests {
    private typealias R = HostAdmissionSceneRoute

    private func stateWithWindow() throws -> RouterState<R> {
        try .init(root: .stack(), windows: [.init(route: .window)])
    }

    private var allowed: RouterHostDescriptor<R> {
        .init(root: .stack, windows: .stack)
    }

    private var oversized: RouterHostDescriptor<R> {
        .init(root: .stack, windows: .init(entries: [
            .init("window", shape: .stack), .init("unused", shape: .stack),
        ], declaration: { _ in "window" }))
    }

    private func smallBudget() throws -> RouterResourceBudget {
        .init(snapshot: try .init(maximumNodes: 3))
    }

    @Test("Unused oversized declarations reject before scene metadata lookup during creation")
    func creationPreflight() throws {
        let state = try stateWithWindow()
        let budget = try smallBudget()
        R.sceneLookups.withLock { $0 = 0 }
        do {
            _ = try RouterStore(initialState: state, configuration: .init(
                resourceBudget: budget, hostDescriptor: oversized
            ))
            Issue.record("Expected the unused fourth declaration node to exceed the descriptor budget")
        } catch let failure as RouterHostValidationFailure {
            #expect(failure.code == .resourceLimit)
            #expect(failure.resourceLimit?.resource == "hostShape.nodes")
        }
        #expect(R.sceneLookups.withLock { $0 } == 0)

        let store = try RouterStore(initialState: state, configuration: .init(
            resourceBudget: budget, hostDescriptor: allowed
        ))
        #expect(store.state == state)
        #expect(R.sceneLookups.withLock { $0 } > 0)
    }

    @Test("Ordinary public candidates reject unknown host declarations before scene callbacks")
    func candidatePreflight() async throws {
        let state = try stateWithWindow()
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: .init(root: .stack)))
        R.sceneLookups.withLock { $0 = 0 }
        guard case .rejected(_, _, _, .hostContract(let failure)) = await store.perform(.apply(.init(state: state))) else {
            Issue.record("An undeclared window must fail host admission"); return
        }
        #expect(failure.code == .unknownDeclaration)
        #expect(R.sceneLookups.withLock { $0 } == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)

        guard case .applied = await store.replaceHost(with: .init(state: state), descriptor: allowed) else {
            Issue.record("Declaring the same window must permit the candidate"); return
        }
        #expect(R.sceneLookups.withLock { $0 } > 0)
        #expect(store.state == state)
        #expect(store.revision == 1)
    }

    @Test("Owner replacement admits the complete unused catalog before scene callbacks")
    func replacementPreflight() async throws {
        let state = try stateWithWindow()
        let store = try RouterStore<R>(configuration: .init(
            resourceBudget: smallBudget(), hostDescriptor: .init(root: .stack)
        ))
        let generation = store.committedValue.hostGeneration
        R.sceneLookups.withLock { $0 = 0 }
        guard case .rejected(_, _, _, .hostContract(let failure)) = await store.replaceHost(
            with: .init(state: state), descriptor: oversized
        ) else {
            Issue.record("Expected oversized replacement declaration rejection"); return
        }
        #expect(failure.code == .resourceLimit)
        #expect(R.sceneLookups.withLock { $0 } == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.committedValue.hostGeneration == generation)

        guard case .applied = await store.replaceHost(with: .init(state: state), descriptor: allowed) else {
            Issue.record("Matching bounded replacement must remain supported"); return
        }
        #expect(R.sceneLookups.withLock { $0 } > 0)
        #expect(store.state == state)
        #expect(store.revision == 1)
    }

    @Test("Cancellation while final host validation runs rejects before commit")
    func cancelledDuringFinalValidation() async throws {
        let gate = HostAdmissionResolverGate()
        defer { gate.finish() }
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: .init(root: .stack)))
        let before = store.state, generation = store.committedValue.hostGeneration
        let target = try stateWithWindow()
        let descriptor = RouterHostDescriptor<R>(root: .stack, windows: .init(
            entries: [.init("window", shape: .stack)], declaration: { _ in gate.resolve() }
        ))
        let replacement = Task { await store.replaceHost(with: .init(state: target), descriptor: descriptor) }
        defer { replacement.cancel() }
        // Final validation is synchronous on MainActor. A detached controller
        // cancels the request and releases its application callback without
        // relying on MainActor resumption or timing-based sleeps.
        let controller = Task.detached {
            var entered = gate.entered.makeAsyncIterator()
            if await entered.next() != nil { replacement.cancel() }
            gate.release()
        }
        let outcome = await replacement.value
        gate.finish()
        await controller.value
        #expect(gate.count == 3)
        #expect(!gate.timedOut)
        guard case .rejected(_, _, _, .cancelled) = outcome else {
            Issue.record("Cancellation during final validation must not publish a replacement"); return
        }
        #expect(store.state == before)
        #expect(store.revision == 0)
        #expect(store.committedValue.hostGeneration == generation)
        try store.validateHostRenderer(shape: .stack, at: .root)
    }
}
