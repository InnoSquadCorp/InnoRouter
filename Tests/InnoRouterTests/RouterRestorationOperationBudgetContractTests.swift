import Foundation
import Testing

import InnoRouterCore
#if canImport(InnoRouterRestorationContracts)
@testable import InnoRouterRestorationContracts
#else
@testable import InnoRouterSwiftUI
#endif

enum RestorationBudgetRoute: Route, Codable { case step(Int) }

@MainActor
final class RestorationBudgetLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class RestorationBudgetGate {
    let entered = RestorationBudgetLatch()
    let released = RestorationBudgetLatch()
    let exited = RestorationBudgetLatch()
    private(set) var hasExited = false
    private(set) var wasCancelled = false

    func suspend() async {
        entered.open()
        // Deliberately retains actual application work past logical completion.
        await released.wait()
        wasCancelled = Task.isCancelled
        hasExited = true
        exited.open()
    }
}

@MainActor
final class RestorationBudgetWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

@Suite("Restoration planner actual operation budget", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterRestorationOperationBudgetContractTests {
    private typealias R = RestorationBudgetRoute

    @Test("One thousand attempts cannot replace a still-running timed-out or cancelled planner", arguments: ["timeout", "cancel", "fallback"])
    func saturatedOperationsStayBounded(terminal: String) async throws {
        let operations = RouterOperationRegistry(maximumCount: 1)
        let gate = RestorationBudgetGate()
        let timer = RestorationBudgetGate()
        var validationCalls = 0
        var fallbackCalls = 0
        var terminals = 0
        let source = RouterState<R>.rootStack(path: [.step(0), .step(1)])
        let validator = RouterPartialRestorationValidator<R>(
            fallback: { _ in
                fallbackCalls += 1
                await gate.suspend()
                return .step(2)
            },
            validate: { _, _ in
                validationCalls += 1
                if terminal == "fallback" { return .remove(reason: "retired") }
                await gate.suspend()
                return .keep
            }
        )
        let task = Task { @MainActor in
            defer { terminals += 1 }
            return try await preparePartialRestoration(
                source, validator: validator, operations: operations,
                timeout: terminal == "timeout" ? .seconds(30) : nil,
                sleep: { _ in await timer.suspend() }
            )
        }
        await gate.entered.wait()
        if terminal == "timeout" {
            await timer.entered.wait()
            timer.released.open()
        } else {
            task.cancel()
        }
        let expected: RouterPartialRestorationError = terminal == "timeout" ? .validationTimedOut : .cancelled
        await #expect(throws: expected) { try await task.value }
        #expect(terminals == 1)
        #expect(operations.activeCount == 1)
        #expect(!gate.hasExited)

        var rejected = 0
        var extraCalls = 0
        for _ in 0..<1_000 {
            do {
                _ = try await preparePartialRestoration(
                    source,
                    validator: .init { _, _ in extraCalls += 1; return .keep },
                    operations: operations, timeout: nil, sleep: { _ in }
                )
            } catch let error as RouterPartialRestorationError {
                #expect(error == .operation(.capacityExceeded(maximumCount: 1, activeCount: 1)))
                rejected += 1
            }
        }
        #expect(rejected == 1_000)
        #expect(extraCalls == 0)
        #expect(validationCalls == 1)
        #expect(fallbackCalls == (terminal == "fallback" ? 1 : 0))
        #expect(operations.activeCount == 1)
        #expect(source == .rootStack(path: [.step(0), .step(1)]))

        gate.released.open()
        await gate.exited.wait()
        #expect(gate.wasCancelled)
        #expect(validationCalls == 1)
        #expect(fallbackCalls == (terminal == "fallback" ? 1 : 0))
        #expect(operations.activeCount == 0)
        #expect(terminals == 1)
        let recovered = try await preparePartialRestoration(
            source, validator: .init { _, _ in .keep }, operations: operations,
            timeout: nil, sleep: { _ in }
        )
        #expect(recovered.0 == source)
        #expect(operations.activeCount == 0)
        #expect(terminals == 1)
    }

    @Test("A single slot covers all sequential routes, replacements and fallback callbacks")
    func sequentialCallbacksShareOneOperation() async throws {
        let operations = RouterOperationRegistry(maximumCount: 1)
        var calls = 0
        let result = try await preparePartialRestoration(
            RouterState<R>.rootStack(path: [.step(0)]),
            validator: .init(fallback: { _ in
                #expect(operations.activeCount == 1)
                return .step(1)
            }, validate: { route, _ in
                calls += 1
                #expect(operations.activeCount == 1)
                if route == .step(0) { return .remove(reason: "retired") }
                if route == .step(1) { return .replace(with: .step(2), reason: "upgraded") }
                return .keep
            }),
            operations: operations, timeout: nil, sleep: { _ in }
        )
        #expect(result.0 == .rootStack(path: [.step(2)]))
        #expect(calls == 3)
        #expect(operations.activeCount == 0)
    }

    @Test("Cancelled callers do not reserve or invoke callbacks even at zero capacity")
    func cancellationBeforeAdmission() async {
        let operations = RouterOperationRegistry(maximumCount: 0)
        var calls = 0
        let task = Task { @MainActor in
            try await preparePartialRestoration(
                RouterState<R>.rootStack(path: [.step(0)]),
                validator: .init { _, _ in calls += 1; return .keep },
                operations: operations, timeout: nil, sleep: { _ in }
            )
        }
        task.cancel()
        await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
        #expect(calls == 0)
        #expect(operations.activeCount == 0)
    }

    @Test("One thousand cancellation and actual-exit cycles return every reservation")
    func repeatedCancellationCleanup() async {
        let operations = RouterOperationRegistry(maximumCount: 1)
        var terminals = 0
        var validationCalls = 0
        for index in 0..<1_000 {
            let gate = RestorationBudgetGate()
            let task = Task { @MainActor in
                defer { terminals += 1 }
                return try await preparePartialRestoration(
                    RouterState<R>.rootStack(path: [.step(index)]),
                    validator: .init { _, _ in
                        validationCalls += 1
                        await gate.suspend()
                        return .keep
                    },
                    operations: operations, timeout: nil, sleep: { _ in }
                )
            }
            await gate.entered.wait()
            task.cancel()
            await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
            #expect(operations.activeCount == 1)
            gate.released.open()
            await gate.exited.wait()
            #expect(operations.activeCount == 0)
            #expect(terminals == index + 1)
        }
        #expect(validationCalls == 1_000)
        #expect(terminals == 1_000)
    }

    @Test("Extensible capacity diagnostics round trip known and unknown codes without payloads")
    func extensibleDiagnostics() throws {
        let known = RouterRestorationOperationFailure.capacityExceeded(maximumCount: 8, activeCount: 8)
        let unknown = RouterRestorationOperationFailure(code: .init(rawValue: "future.restoration.resource"))
        for failure in [known, unknown] {
            let data = try JSONEncoder().encode(failure)
            #expect(try JSONDecoder().decode(RouterRestorationOperationFailure.self, from: data) == failure)
            #expect(failure.description == failure.code.rawValue)
        }
        #expect(known.code == .capacityExceeded)
        #expect(known.details.maximumCount == 8)
        #expect(known.details.activeCount == 8)
        #expect(unknown.details.maximumCount == nil)
    }
}
