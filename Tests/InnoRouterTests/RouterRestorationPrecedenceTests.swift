import Foundation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum PrecedenceError: Error { case load, timeout }
private enum PrecedenceLoad: Sendable { case snapshot, missing, failed, corrupt }

private enum PrecedenceRoute: String, Route, Codable {
    case saved, early, later
}

/// Storage whose `load()` stays open on a real thread until the test releases
/// it, so a request can be made while the initial snapshot is still loading.
private final class PrecedenceStorage: RouterSnapshotStorage {
    let loads: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let loadBarrier = DispatchSemaphore(value: 0)
    private let result: PrecedenceLoad
    private let saved = Mutex<Data?>(nil)

    init(_ result: PrecedenceLoad = .snapshot) {
        self.result = result
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        releaseLoad()
        loadContinuation.finish()
    }

    var data: Data? { saved.withLock { $0 } }
    func releaseLoad() { loadBarrier.signal() }

    func load() throws -> Data? {
        loadContinuation.yield()
        guard loadBarrier.wait(timeout: .now() + 5) == .success else { throw PrecedenceError.timeout }
        switch result {
        case .missing: return nil
        case .failed: throw PrecedenceError.load
        case .corrupt: return Data("not a snapshot".utf8)
        case .snapshot:
            return try RouterSnapshotCodec<PrecedenceRoute>(currentVersion: 1)
                .encode(.rootStack(path: [.saved]))
        }
    }

    func save(_ data: Data) throws { saved.withLock { $0 = data } }
    func remove() throws { saved.withLock { $0 = nil } }
}

/// `RouterRestorationPrecedence` decides what happens to navigation requested
/// while the initial snapshot is still loading. With `.snapshot` nothing
/// commits until the snapshot has been applied; what was requested meanwhile
/// then runs under the ordinary rules, which reject a request written for a
/// scope the restore replaced.
@Suite("Restoration precedence", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterRestorationPrecedenceTests {
    private typealias R = PrecedenceRoute
    private typealias Activation = Task<RouterRestorationDriverActivation<R>, any Error>

    private struct Fixture {
        let store: RouterStore<R>
        let storage: PrecedenceStorage
        let driver: RouterRestorationDriver<R>
    }

    private func makeFixture(
        _ precedence: RouterRestorationPrecedence,
        load: PrecedenceLoad = .snapshot,
        scheduling: RouterSchedulingPolicy = .serialize
    ) throws -> Fixture {
        let storage = PrecedenceStorage(load)
        let store = try RouterStore<R>(configuration: .init(schedulingPolicy: scheduling))
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage,
            saveDebounce: .zero
        )
        driver.initialRestorePrecedence = precedence
        return Fixture(store: store, storage: storage, driver: driver)
    }

    /// Starts activation and returns once the storage load is open.
    private func beginLoading(_ fixture: Fixture) async throws -> Activation {
        let activating = Activation { try await fixture.driver.activate() }
        _ = try await firstElement(from: fixture.storage.loads, what: "the initial load entered")
        return activating
    }

    @Test("The default precedence keeps a navigation committed during the load")
    func navigationPrecedenceIsDefault() async throws {
        let fixture = try makeFixture(.navigation)
        #expect(RouterRestorationDriver(
            store: fixture.store, codec: try .init(currentVersion: 1), storage: PrecedenceStorage()
        ).initialRestorePrecedence == .navigation)
        let activating = try await beginLoading(fixture)
        defer { fixture.storage.releaseLoad(); activating.cancel(); fixture.driver.stop() }

        guard case .applied = await fixture.store.perform(.push(.early)) else {
            Issue.record("The push during the load did not commit")
            return
        }
        fixture.storage.releaseLoad()

        guard case .restored(let outcome) = try await activating.value,
              case .rejected(_, _, _, .staleState) = outcome.transition else {
            Issue.record("Expected the snapshot to be rejected as stale")
            return
        }
        #expect(fixture.store.state.root == .stack(path: [.early]))
    }

    @Test("Snapshot precedence applies the snapshot first, then Store-level requests in order")
    func snapshotPrecedenceOrdersRestoreFirst() async throws {
        let fixture = try makeFixture(.snapshot)
        let activating = try await beginLoading(fixture)
        defer { fixture.storage.releaseLoad(); activating.cancel(); fixture.driver.stop() }

        let push = Task { await fixture.store.perform(.push(.early)) }
        let second = Task { await fixture.store.perform(.push(.later)) }
        try await waitUntil("both requests are queued behind the restore") {
            fixture.store.queuedRequests.count == 2
        }
        #expect(fixture.store.state.root == .stack(path: []))
        #expect(fixture.store.revision == 0)

        fixture.storage.releaseLoad()

        guard case .restored(let outcome) = try await activating.value,
              case .applied = outcome.transition else {
            Issue.record("The initial restore did not apply")
            return
        }
        guard case .applied = await push.value, case .applied = await second.value else {
            Issue.record("A queued request did not apply after the restore")
            return
        }
        // Restore, then the two requests in the order they were made.
        #expect(fixture.store.state.root == .stack(path: [.saved, .early, .later]))
        #expect(fixture.store.revision == 3)
        #expect(fixture.store.activeTransitionID == nil)
        #expect(fixture.store.reservedLaneID == nil)
        #expect(fixture.driver.status == .active)
    }

    @Test("A missing snapshot or a failed load releases the held requests")
    func holdEndsWithoutASnapshot() async throws {
        for load in [PrecedenceLoad.missing, .failed] {
            let fixture = try makeFixture(.snapshot, load: load)
            let activating = try await beginLoading(fixture)
            defer { fixture.storage.releaseLoad(); activating.cancel(); fixture.driver.stop() }

            let push = Task { await fixture.store.perform(.push(.early)) }
            try await waitUntil("the request is queued behind the load") {
                fixture.store.queuedRequests.count == 1
            }
            fixture.storage.releaseLoad()

            if load == .failed {
                await #expect(throws: PrecedenceError.load) { try await activating.value }
            } else {
                #expect(try await activating.value == .noSnapshot)
            }
            guard case .applied = await push.value else {
                Issue.record("The held request did not apply after a \(load) load")
                return
            }
            #expect(fixture.store.state.root == .stack(path: [.early]))
            #expect(fixture.store.reservedLaneID == nil)
            #expect(fixture.store.activeTransitionID == nil)
        }
    }

    @Test("Stopping the driver during the load releases the lane at once")
    func stopReleasesTheHold() async throws {
        let fixture = try makeFixture(.snapshot)
        let activating = try await beginLoading(fixture)
        defer { fixture.storage.releaseLoad(); activating.cancel() }

        let push = Task { await fixture.store.perform(.push(.early)) }
        try await waitUntil("the request is queued behind the load") {
            fixture.store.queuedRequests.count == 1
        }

        // The storage load is still open; the Store must not stay frozen.
        fixture.driver.stop()
        guard case .applied = await push.value else {
            Issue.record("The held request did not run after stop")
            return
        }
        #expect(fixture.store.state.root == .stack(path: [.early]))
        #expect(fixture.store.reservedLaneID == nil)
        await #expect(throws: CancellationError.self) { try await activating.value }

        // A later restore result must not replace the committed state.
        fixture.storage.releaseLoad()
        try await waitUntil("the driver settled as inactive") { fixture.driver.status == .inactive }
        #expect(fixture.store.state.root == .stack(path: [.early]))
    }

    @Test("Under reject-while-busy a request during the hold is rejected as busy")
    func rejectWhileBusyDuringHold() async throws {
        let fixture = try makeFixture(.snapshot, scheduling: .rejectWhileBusy)
        let activating = try await beginLoading(fixture)
        defer { fixture.storage.releaseLoad(); activating.cancel(); fixture.driver.stop() }

        guard case .rejected(_, _, _, .busy) = await fixture.store.perform(.push(.early)) else {
            Issue.record("Expected a busy rejection during the hold")
            return
        }
        fixture.storage.releaseLoad()

        guard case .restored(let outcome) = try await activating.value,
              case .applied = outcome.transition else {
            Issue.record("The initial restore did not apply")
            return
        }
        #expect(fixture.store.state.root == .stack(path: [.saved]))
    }

    @Test("A request already executing when activation starts keeps its place")
    func busyStoreFallsBackToNavigationPrecedence() async throws {
        let storage = PrecedenceStorage()
        let gate = AsyncStream.makeStream(of: Void.self)
        let entered = AsyncStream.makeStream(of: Void.self)
        var configuration = RouterStoreConfiguration<R>()
        configuration.policies = [RouterPolicy(name: "slow") { _ in
            entered.continuation.yield()
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return .allow
        }]
        let store = try RouterStore<R>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage, saveDebounce: .zero
        )
        driver.initialRestorePrecedence = .snapshot

        let push = Task { await store.perform(.push(.early)) }
        _ = try await firstElement(from: entered.stream, what: "the policy is evaluating")
        let activating = Activation { try await driver.activate() }
        defer { gate.continuation.finish(); storage.releaseLoad(); activating.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.loads, what: "the initial load entered")
        #expect(store.reservedLaneID == nil)

        gate.continuation.yield()
        guard case .applied = await push.value else {
            Issue.record("The executing request did not apply")
            return
        }
        storage.releaseLoad()

        guard case .restored(let outcome) = try await activating.value,
              case .rejected(_, _, _, .staleState) = outcome.transition else {
            Issue.record("Expected the snapshot to be stale behind the earlier request")
            return
        }
        #expect(store.state.root == .stack(path: [.early]))
    }

    @Test("A view's request made during the hold never displaces the snapshot", arguments: [
        RouterDispatchTiming.deferred, .immediateWhenIdle,
    ])
    func viewRequestsDoNotDisplaceTheSnapshot(timing: RouterDispatchTiming) async throws {
        let storage = PrecedenceStorage()
        var configuration = RouterStoreConfiguration<R>()
        configuration.dispatchTiming = timing
        let store = try RouterStore<R>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage, saveDebounce: .zero
        )
        driver.initialRestorePrecedence = .snapshot
        let scope = store.scope()
        let router = RouterActions(authority: RouterAuthority(scope: scope))
        let activating = Activation { try await driver.activate() }
        defer { storage.releaseLoad(); activating.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.loads, what: "the initial load entered")

        // A router call, a scoped request, a root request such as a host's
        // deep-link handling, and the absolute write a NavigationStack
        // binding makes when the user taps a link.
        let routed = router.go(.early)
        let scoped = Task { await scope.perform(.push(.early)) }
        let rooted = Task { await scope.performRoot(.push(.early)) }
        let bound = scope.dispatch(.replaceStack([.early]), context: .init(source: .system))
        #expect(store.state.root == .stack(path: []))
        try await waitUntil("all four requests wait behind the restore") {
            store.queuedRequests.count == 4
        }
        storage.releaseLoad()

        guard case .restored(let outcome) = try await activating.value,
              case .applied = outcome.transition else {
            Issue.record("The initial restore did not apply")
            return
        }
        for (name, result) in [
            ("router", await routed.value), ("scoped", await scoped.value),
            ("root", await rooted.value), ("binding", await bound.value),
        ] {
            guard case .rejected(_, _, _, .mutation(.expiredScope)) = result else {
                Issue.record("The \(name) request was not rejected as an expired scope: \(result)")
                continue
            }
        }
        // Only the restore committed: the previous session is intact.
        #expect(store.state.root == .stack(path: [.saved]))
        #expect(store.revision == 1)
        #expect(store.reservedLaneID == nil)
        // The scope the restore installed accepts requests as usual.
        guard case .applied = await store.scope().perform(.push(.later)) else {
            Issue.record("The restored scope rejected a request")
            return
        }
        #expect(store.state.root == .stack(path: [.saved, .later]))
    }

    @Test("An awaited presentation requested during the hold does not survive the restore")
    func awaitedPresentationDuringHold() async throws {
        let fixture = try makeFixture(.snapshot)
        let scope = fixture.store.scope()
        let activating = try await beginLoading(fixture)
        defer { fixture.storage.releaseLoad(); activating.cancel(); fixture.driver.stop() }

        let presenting = Task { await scope.present(.early, expecting: Int.self) }
        try await waitUntil("the presentation waits behind the restore") {
            fixture.store.queuedRequests.count == 1
        }
        fixture.storage.releaseLoad()
        _ = try await activating.value

        switch await presenting.value {
        case .cancelled, .rejected:
            break
        case .value, .dismissed:
            Issue.record("A presentation written for the replaced scope was shown")
        }
        #expect(fixture.store.state.root == .stack(path: [.saved]))
    }

    @Test("A detached activation's worker cannot release the next activation's hold")
    func staleWorkerLeavesTheNewHold() async throws {
        let fixture = try makeFixture(.snapshot)
        let firstID = UUID()
        let first = Activation { try await fixture.driver.attach(firstID) }
        _ = try await firstElement(from: fixture.storage.loads, what: "the first load entered")
        let firstLane = try #require(fixture.store.reservedLaneID)

        fixture.driver.detach(firstID)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(fixture.store.reservedLaneID == nil)

        // The first load is still blocking its storage worker.
        let secondID = UUID()
        let second = Activation { try await fixture.driver.attach(secondID) }
        defer {
            fixture.storage.releaseLoad(); fixture.storage.releaseLoad()
            second.cancel(); fixture.driver.stop()
        }
        try await waitUntil("the second activation holds the lane") {
            fixture.store.reservedLaneID != nil
        }
        let secondLane = try #require(fixture.store.reservedLaneID)
        #expect(secondLane != firstLane)
        let push = Task { await fixture.store.perform(.push(.early)) }
        try await waitUntil("the request is queued behind the second hold") {
            fixture.store.queuedRequests.count == 1
        }

        // Let the stale worker finish. Its release must be a no-op now.
        fixture.storage.releaseLoad()
        _ = try await firstElement(from: fixture.storage.loads, what: "the second load entered")
        #expect(fixture.store.reservedLaneID == secondLane)
        #expect(fixture.store.state.root == .stack(path: []))

        fixture.storage.releaseLoad()
        guard case .restored(let outcome) = try await second.value,
              case .applied = outcome.transition, case .applied = await push.value else {
            Issue.record("The second activation did not restore first")
            return
        }
        #expect(fixture.store.state.root == .stack(path: [.saved, .early]))
    }

    @Test("A snapshot that fails to decode releases the hold without announcing a request")
    func decodeFailureReleasesQuietly() async throws {
        let fixture = try makeFixture(.snapshot, load: .corrupt)
        let cancelled = TestCell(0)
        fixture.store.addSynchronousCancellationObserver { _ in cancelled.value += 1 }
        let activating = try await beginLoading(fixture)
        defer { fixture.storage.releaseLoad(); activating.cancel(); fixture.driver.stop() }

        let push = Task { await fixture.store.perform(.push(.early)) }
        try await waitUntil("the request is queued behind the load") {
            fixture.store.queuedRequests.count == 1
        }
        fixture.storage.releaseLoad()

        await #expect(throws: (any Error).self) { try await activating.value }
        guard case .applied = await push.value else {
            Issue.record("The held request did not run after the decode failure")
            return
        }
        #expect(fixture.store.state.root == .stack(path: [.early]))
        #expect(fixture.store.reservedLaneID == nil)
        // The reserved id was never a request, so nothing was cancelled.
        #expect(cancelled.value == 0)
    }

    @Test("A policy that defers the restoration ends the hold with the deferral")
    func deferredRestoreEndsTheHold() async throws {
        let storage = PrecedenceStorage()
        let deferral = RouterDeferralID()
        var configuration = RouterStoreConfiguration<R>()
        configuration.policies = [RouterPolicy(name: "review restores") { transition in
            transition.context.source == .restoration ? .deferRequest(deferral) : .allow
        }]
        let store = try RouterStore<R>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage, saveDebounce: .zero
        )
        driver.initialRestorePrecedence = .snapshot
        let activating = Activation { try await driver.activate() }
        defer { storage.releaseLoad(); activating.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.loads, what: "the initial load entered")

        let push = Task { await store.perform(.push(.early)) }
        try await waitUntil("the request is queued behind the load") {
            store.queuedRequests.count == 1
        }
        storage.releaseLoad()

        guard case .restored(let outcome) = try await activating.value,
              case .deferred = outcome.transition else {
            Issue.record("Expected the restore to be deferred by the policy")
            return
        }
        // Documented limit: the Store cannot stay closed for an open-ended
        // decision, so the queued request now runs before the snapshot.
        guard case .applied = await push.value else {
            Issue.record("The queued request did not run after the deferral")
            return
        }
        #expect(store.state.root == .stack(path: [.early]))
        #expect(store.reservedLaneID == nil)
        #expect(store.activeTransitionID == nil)
    }
}
