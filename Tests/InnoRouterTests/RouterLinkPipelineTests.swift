import Foundation
import Observation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterDeepLink
import InnoRouterSwiftUI

@Suite("RouterLinkPipeline")
struct RouterLinkPipelineTests {
    private enum RouteFixture: Route, Codable {
        case home
        case detail(String)
        case signIn
    }

    @MainActor
    private final class Session {
        var isAuthenticated = false
    }

    private final class BlockingPendingLinkStorage: RouterPendingLinkStorage {
        private let started = Mutex(false)
        private let release = DispatchSemaphore(value: 0)
        private let storedData: Mutex<Data?>
        private let onLoad: @Sendable () -> Void

        init(data: Data, onLoad: @escaping @Sendable () -> Void = {}) {
            self.storedData = Mutex(data)
            self.onLoad = onLoad
        }

        var loadStarted: Bool { started.withLock { $0 } }
        var hasData: Bool { storedData.withLock { $0 != nil } }
        func unblock() { release.signal() }

        func load() throws -> Data? {
            started.withLock { $0 = true }
            onLoad()
            release.wait()
            return storedData.withLock { $0 }
        }

        func save(_ data: Data) throws { storedData.withLock { $0 = data } }
        func remove() throws { storedData.withLock { $0 = nil } }
    }

    @MainActor
    private final class FirstResumePolicyGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var hasBlocked = false

        func decide() async -> RouterPolicyDecision {
            guard !hasBlocked else { return .allow }
            hasBlocked = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation = $0 }
            return .allow
        }

        func waitUntilEntered() async {
            if hasBlocked { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class WeakStoreReference {
        weak var value: RouterStore<RouteFixture>?

        init(_ value: RouterStore<RouteFixture>) {
            self.value = value
        }
    }

    private struct FixedPendingLinkStorage: RouterPendingLinkStorage {
        let data: Data?
        func load() throws -> Data? { data }
        func save(_ data: Data) throws {}
        func remove() throws {}
    }

    enum StorageFailurePoint: Sendable, CaseIterable {
        case load
        case save
        case remove
    }

    private struct FailingPendingLinkStorage: RouterPendingLinkStorage {
        struct Failure: Error {}

        let point: StorageFailurePoint

        func load() throws -> Data? {
            if point == .load { throw Failure() }
            return nil
        }

        func save(_ data: Data) throws {
            if point == .save { throw Failure() }
        }

        func remove() throws {
            if point == .remove { throw Failure() }
        }
    }

    @Test("One URL resolves directly to a complete router plan")
    func completePlan() async throws {
        let matcher = DeepLinkMatcher<RouterPlan<RouteFixture>> {
            DeepLinkMapping("/detail/:id") { parameters in
                guard let id = parameters.firstValue(forName: "id") else { return nil }
                return RouterPlan(
                    state: .rootStack(path: [.home, .detail(id)])
                )
            }
        }
        let pipeline = RouterLinkPipeline(
            originPolicy: .allowlisted(schemes: ["innorouter"], hosts: ["app"]),
            matcher: matcher
        )

        guard case .plan(let plan) = await pipeline.decide(
            for: try #require(URL(string: "innorouter://app/detail/42"))
        ) else {
            Issue.record("Expected complete plan")
            return
        }
        #expect(plan.state.root == .stack(path: [.home, .detail("42")]))
    }

    @Test("Authentication scans every surface in the whole-app plan")
    @MainActor
    func wholeStateAuthentication() async throws {
        let session = Session()
        let plan = RouterPlan(
            state: try RouterState<RouteFixture>(
                root: .stack(path: [.home]),
                windows: [.init(route: .signIn)]
            )
        )
        let pipeline = RouterLinkPipeline<RouteFixture>(
            originPolicy: .allowlisted(schemes: ["innorouter"], hosts: ["app"]),
            customResolver: { _ in plan },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .signIn },
                isAuthenticated: { await session.isAuthenticated }
            )
        )
        let url = try #require(URL(string: "innorouter://app/protected"))

        guard case .pending(let pending) = await pipeline.decide(for: url) else {
            Issue.record("Expected pending plan")
            return
        }
        #expect(pending.url == url)
        #expect(pending.gatedRoute == .signIn)
        #expect(pending.plan == plan)
    }

    @Test("Origin validation remains fail closed")
    func originRejection() async throws {
        let pipeline = RouterLinkPipeline<RouteFixture>(
            originPolicy: .allowlisted(schemes: ["innorouter"], hosts: ["app"]),
            customResolver: { _ in RouterPlan(state: .rootStack) }
        )

        #expect(
            await pipeline.decide(
                for: try #require(URL(string: "https://evil.example/home"))
            )
                == .rejected(reason: .schemeNotAllowed(actualScheme: "https"))
        )
    }

    @Test("Pending links resume their exact plan with explicit provenance")
    @MainActor
    func pendingResume() async throws {
        let plan = RouterPlan(
            state: RouterState<RouteFixture>.rootStack(path: [.home, .detail("42")])
        )
        let url = try #require(URL(string: "innorouter://app/protected"))
        let pending = PendingRouterLink(url: url, gatedRoute: .detail("42"), plan: plan)
        let store = RouterStore<RouteFixture>()
        var events = store.events.makeAsyncIterator()

        let execution = await pending.resume(on: store, source: .appIntent)

        guard case .completed(let resumedPlan, .applied) = execution else {
            Issue.record("Expected the retained plan to be applied")
            return
        }
        #expect(resumedPlan == plan)
        guard case .started(let transition) = await events.next() else {
            Issue.record("Expected a started transition")
            return
        }
        #expect(transition.context.source == .appIntent)
        #expect(store.state == plan.state)
    }

    @Test("Pending slot replacement, cancellation, and rejection retention are explicit")
    @MainActor
    func pendingSlotLifecycle() async throws {
        let first = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/first")),
            gatedRoute: .detail("first"),
            plan: RouterPlan(state: .rootStack(path: [.detail("first")]))
        )
        let second = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/second")),
            gatedRoute: .detail("second"),
            plan: RouterPlan(state: .rootStack(path: [.detail("second")]))
        )
        let slot = RouterPendingLinkSlot<RouteFixture>()

        #expect(slot.submit(first) == .stored(first))
        #expect(slot.submit(second, replacing: .keepExisting) == .keptExisting(first))
        #expect(slot.pending == first)
        #expect(
            slot.submit(second) == .replaced(previous: first, current: second)
        )

        let rejectingStore = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [RouterPolicy(name: "blocked") { _ in .reject("not ready") }]
            )
        )
        guard case .completed(_, .rejected) = await slot.resume(on: rejectingStore) else {
            Issue.record("Expected policy rejection")
            return
        }
        #expect(slot.pending == second)
        #expect(slot.cancel() == second)
        #expect(slot.pending == nil)
    }

    @Test("An identical replacement survives a suspended resume")
    @MainActor
    func identicalPendingReplacementDuringResume() async throws {
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/protected")),
            gatedRoute: .detail("protected"),
            plan: RouterPlan(state: .rootStack(path: [.detail("protected")]))
        )
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ]
            )
        )
        var events = store.events.makeAsyncIterator()
        let slot = RouterPendingLinkSlot(link)
        let resume = Task { @MainActor in
            await slot.resume(on: store)
        }

        guard case .started = await events.next() else {
            Issue.record("Expected the retained plan to begin")
            continuation.finish()
            return
        }
        #expect(slot.submit(link) == .replaced(previous: link, current: link))
        continuation.yield()
        continuation.finish()

        guard case .completed(_, .applied) = await resume.value else {
            Issue.record("Expected the original resume to complete")
            return
        }
        #expect(slot.pending == link)
    }

    @Test("Cancelling a pending slot cancels its in-flight Store request")
    @MainActor
    func pendingSlotCancellationOwnsResumeRequest() async throws {
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/protected")),
            gatedRoute: .detail("protected"),
            plan: RouterPlan(state: .rootStack(path: [.detail("protected")]))
        )
        let gate = FirstResumePolicyGate()
        let store = RouterStore<RouteFixture>(
            configuration: .init(policies: [
                RouterPolicy(name: "non-cooperative-first") { _ in
                    await gate.decide()
                },
            ])
        )
        let slot = RouterPendingLinkSlot(link)
        let resume = Task { @MainActor in await slot.resume(on: store) }
        await gate.waitUntilEntered()

        #expect(slot.cancel() == link)
        guard case .completed(_, .rejected(_, _, _, .cancelled)) = await resume.value else {
            gate.release()
            Issue.record("Expected the owned resume to terminate as cancelled")
            return
        }
        guard case .applied = await store.perform(.push(.home)) else {
            gate.release()
            Issue.record("Expected the serialized lane to be returned immediately")
            return
        }
        gate.release()

        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 1)
        #expect(slot.pending == nil)
    }

    @Test("Driver cancellation owns in-flight resume cancellation and durability")
    @MainActor
    func pendingLinkDriverCancellationOwnsResumeDurability() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/driver-cancel")),
            gatedRoute: .detail("driver-cancel"),
            plan: RouterPlan(state: .rootStack(path: [.detail("driver-cancel")]))
        )
        let gate = FirstResumePolicyGate()
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "non-cooperative-first") { _ in
                await gate.decide()
            },
        ]))
        let slot = RouterPendingLinkSlot<RouteFixture>()
        let driver = RouterPendingLinkPersistenceDriver(
            slot: slot,
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        _ = try await driver.submit(link)
        let resume = Task { @MainActor in try await driver.resume(on: store) }
        await gate.waitUntilEntered()

        #expect(try await driver.cancel() == link)
        guard case .completed(_, .rejected(_, _, _, .cancelled)) =
                try await resume.value else {
            gate.release()
            Issue.record("Expected the driver-owned resume to terminate as cancelled")
            return
        }
        gate.release()

        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(slot.pending == nil)
        #expect(driver.status == .active)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        let verificationDriver = RouterPendingLinkPersistenceDriver(
            slot: RouterPendingLinkSlot<RouteFixture>(),
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        #expect(try await verificationDriver.restore() == .noStoredLink)
    }

    @Test("An unrelated save cannot impersonate driver cancellation ownership")
    @MainActor
    func pendingLinkResumePersistsCallerCancellationAfterConcurrentSave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/caller-cancel")),
            gatedRoute: .detail("caller-cancel"),
            plan: RouterPlan(state: .rootStack(path: [.detail("caller-cancel")]))
        )
        let gate = FirstResumePolicyGate()
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "non-cooperative-first") { _ in
                await gate.decide()
            },
        ]))
        let slot = RouterPendingLinkSlot<RouteFixture>()
        let driver = RouterPendingLinkPersistenceDriver(
            slot: slot,
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        _ = try await driver.submit(link)
        let resume = Task { @MainActor in
            try await driver.resume(on: store, consuming: .always)
        }
        await gate.waitUntilEntered()

        try await driver.save()
        resume.cancel()
        guard case .completed(_, .rejected(_, _, _, .cancelled)) =
                try await resume.value else {
            gate.release()
            Issue.record("Expected caller cancellation to terminate the resume")
            return
        }
        gate.release()

        #expect(slot.pending == nil)
        #expect(driver.status == .active)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Cancelling a pending slot also removes its owned policy deferral")
    @MainActor
    func pendingSlotCancellationOwnsDeferral() async throws {
        let deferralID = RouterDeferralID()
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/deferred")),
            gatedRoute: .detail("deferred"),
            plan: RouterPlan(state: .rootStack(path: [.detail("deferred")]))
        )
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "approval") { transition in
                transition.context.resumedDeferral == nil
                    ? .deferRequest(deferralID)
                    : .allow
            },
        ]))
        let slot = RouterPendingLinkSlot(link)

        guard case .completed(_, .deferred) = await slot.resume(on: store) else {
            Issue.record("Expected the owned resume to defer")
            return
        }
        #expect(store.deferredTransitions.map(\.id) == [deferralID])
        #expect(slot.cancel() == link)
        #expect(store.deferredTransitions.isEmpty)

        guard case .rejected(_, _, _, .deferralNotFound(deferralID)) =
                await store.resumeDeferred(deferralID) else {
            Issue.record("Expected cancellation to consume the owned deferral")
            return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Pending-link cancellation follows a repeatedly deferred request")
    @MainActor
    func pendingSlotCancellationOwnsLatestRepeatedDeferral() async throws {
        let first = RouterDeferralID()
        let second = RouterDeferralID()
        let third = RouterDeferralID()
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/repeated-deferral")),
            gatedRoute: .detail("repeated"),
            plan: RouterPlan(state: .rootStack(path: [.detail("repeated")]))
        )
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "first") { _ in .deferRequest(first) },
            RouterPolicy(name: "second") { _ in .deferRequest(second) },
            RouterPolicy(name: "third") { _ in .deferRequest(third) },
        ]))
        let slot = RouterPendingLinkSlot(link)

        guard case .completed(_, .deferred) = await slot.resume(on: store),
              case .deferred = await store.resumeDeferred(first),
              case .deferred = await store.resumeDeferred(second) else {
            Issue.record("Expected three sequential deferrals")
            return
        }
        #expect(store.deferredTransitions.map(\.id) == [third])

        #expect(slot.cancel() == link)
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Pending-link cancellation interrupts a resumed non-cooperative policy")
    @MainActor
    func pendingSlotCancellationOwnsResumedPolicyExecution() async throws {
        let deferralID = RouterDeferralID()
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/resumed-policy")),
            gatedRoute: .detail("resumed-policy"),
            plan: RouterPlan(state: .rootStack(path: [.detail("resumed-policy")]))
        )
        let gate = FirstResumePolicyGate()
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "approval") { transition in
                guard transition.context.resumedDeferral == nil,
                      case .apply = transition.action else { return .allow }
                return .deferRequest(deferralID)
            },
            RouterPolicy(name: "non-cooperative-resume") { _ in await gate.decide() },
        ]))
        let slot = RouterPendingLinkSlot(link)

        guard case .completed(_, .deferred) = await slot.resume(on: store) else {
            Issue.record("Expected the initial pending request to defer")
            return
        }
        let resumed = Task { @MainActor in await store.resumeDeferred(deferralID) }
        await gate.waitUntilEntered()

        #expect(slot.cancel() == link)
        guard case .rejected(_, _, _, .cancelled) = await resumed.value else {
            gate.release()
            Issue.record("Expected cancellation to terminate the resumed policy")
            return
        }
        guard case .applied = await store.perform(.push(.home)) else {
            gate.release()
            Issue.record("Expected cancellation to release the serialized lane")
            return
        }
        gate.release()

        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 1)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("Keeping a pending link preserves its repeatedly deferred request")
    @MainActor
    func keepExistingPreservesRepeatedDeferral() async throws {
        let first = RouterDeferralID()
        let second = RouterDeferralID()
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/keep-repeated")),
            gatedRoute: .detail("keep"),
            plan: RouterPlan(state: .rootStack(path: [.detail("keep")]))
        )
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "first") { _ in .deferRequest(first) },
            RouterPolicy(name: "second") { _ in .deferRequest(second) },
        ]))
        let slot = RouterPendingLinkSlot(link)

        guard case .completed(_, .deferred) = await slot.resume(on: store),
              case .deferred = await store.resumeDeferred(first) else {
            Issue.record("Expected two sequential deferrals")
            return
        }
        #expect(slot.submit(link, replacing: .keepExisting) == .keptExisting(link))

        guard case .applied = await store.resumeDeferred(second) else {
            Issue.record("Expected the retained request to remain active")
            return
        }
        #expect(store.state == link.plan.state)
        #expect(store.revision == 1)
    }

    @Test("A consumed deferred resume does not extend Store lifetime")
    @MainActor
    func consumedDeferredResumeDoesNotRetainStore() async throws {
        let deferralID = RouterDeferralID()
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/deferred-lifetime")),
            gatedRoute: .detail("deferred-lifetime"),
            plan: RouterPlan(state: .rootStack(path: [.detail("deferred-lifetime")]))
        )
        let slot = RouterPendingLinkSlot(link)
        var store: RouterStore<RouteFixture>? = RouterStore(configuration: .init(policies: [
            RouterPolicy(name: "approval") { _ in .deferRequest(deferralID) },
        ]))
        let released = WeakStoreReference(try #require(store))

        guard case .completed(_, .deferred) = await slot.resume(
            on: try #require(store),
            consuming: .always
        ) else {
            Issue.record("Expected the consumed resume to defer")
            return
        }
        #expect(slot.pending == nil)

        store = nil

        #expect(released.value == nil)
    }

    @Test("Pending-link persistence round trips and removes app-owned storage")
    @MainActor
    func pendingLinkPersistenceRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/protected")),
            gatedRoute: .detail("42"),
            plan: RouterPlan(state: .rootStack(path: [.home, .detail("42")]))
        )
        let firstSlot = RouterPendingLinkSlot<RouteFixture>()
        let firstDriver = RouterPendingLinkPersistenceDriver(
            slot: firstSlot,
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )

        #expect(try await firstDriver.submit(link) == .stored(link))
        let restoredSlot = RouterPendingLinkSlot<RouteFixture>()
        let restoredDriver = RouterPendingLinkPersistenceDriver(
            slot: restoredSlot,
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        #expect(try await restoredDriver.restore() == .restored(.stored(link)))
        #expect(restoredSlot.pending == link)

        #expect(try await restoredDriver.cancel() == link)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("A lifecycle save cannot cancel resume durability after navigation commits")
    @MainActor
    func pendingLinkSaveDuringResumeConvergesAfterConsumption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/protected")),
            gatedRoute: .detail("42"),
            plan: RouterPlan(state: .rootStack(path: [.home, .detail("42")]))
        )
        let (policyGate, policyContinuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "resume-gate") { _ in
                        for await _ in policyGate { break }
                        return .allow
                    }
                ]
            )
        )
        var events = store.events.makeAsyncIterator()
        let slot = RouterPendingLinkSlot<RouteFixture>()
        let driver = RouterPendingLinkPersistenceDriver(
            slot: slot,
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        _ = try await driver.submit(link)
        let resume = Task { @MainActor in
            try await driver.resume(on: store)
        }

        guard case .started = await events.next() else {
            Issue.record("Expected resume to enter the canonical Store pipeline")
            policyContinuation.finish()
            return
        }
        try await driver.save()
        policyContinuation.yield()
        policyContinuation.finish()

        guard case .completed(_, .applied) = try await resume.value else {
            Issue.record("Expected resume to preserve its applied execution")
            return
        }
        #expect(store.revision == 1)
        #expect(slot.pending == nil)
        #expect(driver.status == .active)

        let verificationSlot = RouterPendingLinkSlot<RouteFixture>()
        let verificationDriver = RouterPendingLinkPersistenceDriver(
            slot: verificationSlot,
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        #expect(try await verificationDriver.restore() == .noStoredLink)
        #expect(verificationSlot.pending == nil)
    }

    @Test("Slow pending-link load never overwrites a newer in-memory submission")
    @MainActor
    func pendingLinkPersistenceLoadOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/stored")),
            gatedRoute: .detail("stored"),
            plan: RouterPlan(state: .rootStack(path: [.detail("stored")]))
        )
        let newer = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/newer")),
            gatedRoute: .detail("newer"),
            plan: RouterPlan(state: .rootStack(path: [.detail("newer")]))
        )
        let seedDriver = RouterPendingLinkPersistenceDriver(
            slot: RouterPendingLinkSlot(stored),
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        try await seedDriver.save()
        let storage = BlockingPendingLinkStorage(data: try Data(contentsOf: fileURL))
        let slot = RouterPendingLinkSlot<RouteFixture>()
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage)
        let restoration = Task { @MainActor in try await driver.restore() }

        for _ in 0..<200 where !storage.loadStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(slot.submit(newer) == .stored(newer))
        storage.unblock()

        #expect(try await restoration.value == .supersededByNewerInMemoryLink)
        #expect(slot.pending == newer)
    }

    @Test(
        "A cancelled pending-link restoration cannot resurrect stored navigation",
        arguments: [false, true]
    )
    @MainActor
    func pendingLinkPersistenceCancellationOwnership(cancelDriver: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/stored")),
            gatedRoute: .detail("stored"),
            plan: RouterPlan(state: .rootStack(path: [.detail("stored")]))
        )
        let seed = RouterPendingLinkPersistenceDriver(
            slot: RouterPendingLinkSlot(link),
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        try await seed.save()

        let (loadEvents, loadContinuation) = AsyncStream<Void>.makeStream()
        var loadIterator = loadEvents.makeAsyncIterator()
        let storage = BlockingPendingLinkStorage(
            data: try Data(contentsOf: fileURL),
            onLoad: { loadContinuation.yield() }
        )
        let slot = RouterPendingLinkSlot<RouteFixture>()
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage)
        let restoration = Task { @MainActor in try await driver.restore() }
        _ = await loadIterator.next()

        var cancellation: Task<PendingRouterLink<RouteFixture>?, any Error>?
        if cancelDriver {
            let (statusEvents, statusContinuation) = AsyncStream<Void>.makeStream()
            var statusIterator = statusEvents.makeAsyncIterator()
            withObservationTracking {
                _ = driver.status
            } onChange: {
                statusContinuation.yield()
            }
            cancellation = Task { @MainActor in try await driver.cancel() }
            _ = await statusIterator.next()
        } else {
            restoration.cancel()
        }
        storage.unblock()

        await #expect(throws: CancellationError.self) {
            _ = try await restoration.value
        }
        if let cancellation {
            #expect(try await cancellation.value == nil)
            #expect(!storage.hasData)
        }
        #expect(slot.pending == nil)
        #expect(driver.status == .active)
    }

    @Test("A newer driver submission supersedes a suspended restoration")
    @MainActor
    func pendingLinkPersistenceNewerOperationWins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Pending-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("pending-link.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/stored")),
            gatedRoute: .detail("stored"),
            plan: RouterPlan(state: .rootStack(path: [.detail("stored")]))
        )
        let newer = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/newer")),
            gatedRoute: .detail("newer"),
            plan: RouterPlan(state: .rootStack(path: [.detail("newer")]))
        )
        let seed = RouterPendingLinkPersistenceDriver(
            slot: RouterPendingLinkSlot(stored),
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        try await seed.save()
        let (loadEvents, loadContinuation) = AsyncStream<Void>.makeStream()
        var loadIterator = loadEvents.makeAsyncIterator()
        let storage = BlockingPendingLinkStorage(
            data: try Data(contentsOf: fileURL),
            onLoad: { loadContinuation.yield() }
        )
        let slot = RouterPendingLinkSlot<RouteFixture>()
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage)
        let restoration = Task { @MainActor in try await driver.restore() }
        _ = await loadIterator.next()

        let (statusEvents, statusContinuation) = AsyncStream<Void>.makeStream()
        var statusIterator = statusEvents.makeAsyncIterator()
        withObservationTracking {
            _ = driver.status
        } onChange: {
            statusContinuation.yield()
        }
        let submission = Task { @MainActor in try await driver.submit(newer) }
        _ = await statusIterator.next()
        storage.unblock()

        await #expect(throws: CancellationError.self) {
            _ = try await restoration.value
        }
        #expect(try await submission.value == .stored(newer))
        #expect(slot.pending == newer)
        #expect(driver.status == .active)

        let verificationSlot = RouterPendingLinkSlot<RouteFixture>()
        let verificationDriver = RouterPendingLinkPersistenceDriver(
            slot: verificationSlot,
            storage: storage
        )
        storage.unblock()
        #expect(try await verificationDriver.restore() == .restored(.stored(newer)))
        #expect(verificationSlot.pending == newer)
    }

    @Test("Malformed pending-link storage preserves the live slot")
    @MainActor
    func malformedPendingLinkStorage() async throws {
        let current = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/current")),
            gatedRoute: .detail("current"),
            plan: RouterPlan(state: .rootStack(path: [.detail("current")]))
        )
        let slot = RouterPendingLinkSlot(current)
        let driver = RouterPendingLinkPersistenceDriver(
            slot: slot,
            storage: FixedPendingLinkStorage(data: Data("not-json".utf8))
        )

        await #expect(throws: (any Error).self) {
            _ = try await driver.restore()
        }
        #expect(slot.pending == current)
        guard case .failed = driver.status else {
            Issue.record("Expected visible persistence failure")
            return
        }
    }

    @Test(
        "Pending-link storage failures are visible and never report durable success",
        arguments: StorageFailurePoint.allCases
    )
    @MainActor
    func pendingLinkStorageFailuresAreVisible(point: StorageFailurePoint) async throws {
        let link = PendingRouterLink<RouteFixture>(
            url: try #require(URL(string: "innorouter://app/current")),
            gatedRoute: .detail("current"),
            plan: RouterPlan(state: .rootStack(path: [.detail("current")]))
        )
        let slot = RouterPendingLinkSlot(point == .remove ? link : nil)
        let driver = RouterPendingLinkPersistenceDriver(
            slot: slot,
            storage: FailingPendingLinkStorage(point: point)
        )

        switch point {
        case .load:
            await #expect(throws: FailingPendingLinkStorage.Failure.self) {
                _ = try await driver.restore()
            }
        case .save:
            await #expect(throws: FailingPendingLinkStorage.Failure.self) {
                _ = try await driver.submit(link)
            }
        case .remove:
            await #expect(throws: FailingPendingLinkStorage.Failure.self) {
                _ = try await driver.cancel()
            }
        }
        guard case .failed = driver.status else {
            Issue.record("Expected visible persistence failure")
            return
        }
    }
}
