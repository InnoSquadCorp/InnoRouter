import Foundation
import Observation
import Synchronization
import Testing
import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

/// New implementation fixtures. These are synthetic, never pilot data or a
/// claim to reproduce a lost historical implementation. Static until run.
@Suite("Durable graph pending-link persistence")
struct RouterPendingLinkGraphPersistenceTests {
    private enum Destination: Route { case detail(String) }
    private enum Legacy: Route, Codable { case detail(String) }
    private final class Calls: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func hit() { value.withLock { $0 += 1 } }
    }
    private final class Clock: Sendable {
        private let value: Mutex<Date>
        init(_ value: Date) { self.value = Mutex(value) }
        var date: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0.addTimeInterval(seconds) } }
    }
    private final class MemoryStorage: RouterPendingLinkStorage {
        private let value: Mutex<Data?>
        init(_ data: Data? = nil) { value = Mutex(data) }
        func load() throws -> Data? { value.withLock { $0 } }
        func save(_ data: Data) throws { value.withLock { $0 = data } }
        func remove() throws { value.withLock { $0 = nil } }
    }
    private final class BlockingLoad: RouterPendingLinkStorage {
        private let value: Mutex<Data?>
        private let gate = DispatchSemaphore(value: 0)
        let started: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        init(_ data: Data) {
            value = Mutex(data)
            (started, continuation) = AsyncStream.makeStream()
        }
        func load() throws -> Data? { continuation.yield(); gate.wait(); return value.withLock { $0 } }
        func save(_ data: Data) throws { value.withLock { $0 = data } }
        func remove() throws { value.withLock { $0 = nil } }
        func release() { gate.signal() }
        var hasData: Bool { value.withLock { $0 != nil } }
    }
    private final class BlockingSave: RouterPendingLinkStorage {
        private let value = Mutex<Data?>(nil)
        private let blocked = Mutex(false)
        private let gate = DispatchSemaphore(value: 0)
        let started: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        init() { (started, continuation) = AsyncStream.makeStream() }
        func load() throws -> Data? { value.withLock { $0 } }
        func save(_ data: Data) throws {
            let shouldBlock = blocked.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if shouldBlock { continuation.yield(); gate.wait() }
            value.withLock { $0 = data }
        }
        func remove() throws { value.withLock { $0 = nil } }
        func release() { gate.signal() }
    }
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private func link(_ value: String = "42") -> PendingRouterLink<Destination> {
        .init(url: URL(string: "sample://app/detail/\(value)")!, gatedRoute: .detail(value),
            plan: .init(state: .rootStack(path: [.detail(value)])), matchedRoute: .detail(value))
    }
    private func codec(
        limits: RouterGraphSnapshotLimits = .provisional, version: Int = 7,
        calls: Calls? = nil, lifetime: Duration? = .seconds(86_400),
        migrations: [RouterPendingLinkMigration] = [],
        graphMigrations: [RouterGraphSnapshotMigration] = [], units: Int? = nil, keys: Int? = nil,
        legacy: RouterLegacyPendingLinkReader<Destination>? = nil
    ) throws -> RouterPendingLinkCodec<Destination> {
        let routes = try RouterGraphRouteCodec<Destination>(supportedPayloadVersions: ["stable.detail": 3]) { route in
            switch route { case .detail(let value): .init(stableKey: "stable.detail", payloadVersion: 3, data: Data(value.utf8)) }
        } decode: { payload in calls?.hit(); return .detail(String(decoding: payload.data, as: UTF8.self)) }
        let graph = try RouterGraphSnapshotCodec(schemaID: "synthetic.pending", schemaVersion: version,
            routes: routes, limits: limits, migrations: graphMigrations)
        return try .init(graphCodec: graph, lifetime: lifetime, migrations: migrations, legacyReader: legacy,
            maximumJSONWorkUnits: units, maximumJSONKeyDecodes: keys)
    }
    private func encoded(_ codec: RouterPendingLinkCodec<Destination>? = nil) throws -> Data {
        try (codec ?? self.codec()).encode(.init(link: link(), originatedAt: origin, lastObservedAt: origin))
    }
    private func mutate(_ data: Data, _ edit: (inout RouterPendingLinkGraphEnvelope, inout RouterPendingLinkGraphPayload) throws -> Void) throws -> Data {
        var envelope = try JSONDecoder().decode(RouterPendingLinkGraphEnvelope.self, from: data)
        var payload = try JSONDecoder().decode(RouterPendingLinkGraphPayload.self, from: envelope.payload)
        try edit(&envelope, &payload)
        envelope.payload = try JSONEncoder().encode(payload)
        return try JSONEncoder().encode(envelope)
    }

    @Test("Non-Codable intent round trips through a real atomic file and same slot")
    @MainActor
    func nonCodableFileRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-graph-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(origin)
        let codec = try codec()
        let first = RouterPendingLinkPersistenceDriver(slot: RouterPendingLinkSlot<Destination>(),
            storage: RouterFilePendingLinkStorage(fileURL: url), codec: codec, now: { clock.date })
        _ = try await first.submit(link())
        let slot = RouterPendingLinkSlot<Destination>()
        let restored = RouterPendingLinkPersistenceDriver(slot: slot,
            storage: RouterFilePendingLinkStorage(fileURL: url), codec: codec, now: { clock.date })
        _ = try await restored.restore()
        #expect(slot.pending?.gatedRoute == .detail("42"))
        #expect(slot.pending?.requiresRevalidation == true)
        let store = RouterStore<Destination>()
        guard case .completed(_, .rejected(_, _, _, .authorization(let failure))) = await slot.resume(on: store) else {
            Issue.record("Restored intent must not resume without fresh URL and authorization admission"); return
        }
        #expect(failure.code == .revalidationRequired)
        #expect(store.revision == 0)
        _ = try await restored.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Every composite boundary rejects before the first application route decode")
    func boundariesBeforeRouteDecode() throws {
        let base = try encoded()
        let calls = Calls()
        let reader = try codec(calls: calls)
        let oversized = try mutate(base) { _, payload in payload.gatedRoute.data = Data(repeating: 1, count: 65_537) }
        #expect(throws: (any Error).self) { try reader.decode(oversized, now: origin) }
        let unknown = try mutate(base) { _, payload in payload.matchedRoute?.stableKey = "unknown" }
        #expect(throws: (any Error).self) { try reader.decode(unknown, now: origin) }
        let future = try mutate(base) { envelope, _ in envelope.formatVersion = 999 }
        #expect(throws: RouterPendingLinkPersistenceError.unsupportedFormatVersion(999)) { try reader.decode(future, now: origin) }
        let futureSchema = try mutate(base) { envelope, _ in envelope.schemaVersion = 999 }
        #expect(throws: RouterPendingLinkPersistenceError.unsupportedSchemaVersion(999)) { try reader.decode(futureSchema, now: origin) }
        let limited = try codec(limits: .init(maximumEncodedBytes: base.count - 1), calls: calls)
        #expect(throws: (any Error).self) { try limited.decode(base, now: origin) }
        let shallow = try codec(limits: .init(maximumJSONDepth: 1), calls: calls)
        #expect(throws: (any Error).self) { try shallow.decode(base, now: origin) }
        let fewTokens = try codec(limits: .init(maximumJSONTokens: 1), calls: calls)
        #expect(throws: (any Error).self) { try fewTokens.decode(base, now: origin) }
        let noWork = try codec(calls: calls, units: 0)
        #expect(throws: (any Error).self) { try noWork.decode(base, now: origin) }
        let noKeys = try codec(calls: calls, keys: 0)
        #expect(throws: (any Error).self) { try noKeys.decode(base, now: origin) }
        let combinedRoutes = try codec(limits: .init(maximumRoutes: 2), calls: calls)
        #expect(throws: (any Error).self) { try combinedRoutes.decode(base, now: origin) }
        #expect(calls.count == 0)
        _ = try reader.decode(base, now: origin)
        #expect(calls.count == 3)
    }

    @Test("Corrupt graph markers cannot fall through to an explicit legacy reader")
    func graphMarkerNeverFallsBack() throws {
        let mapped = Calls()
        let legacy = RouterLegacyPendingLinkReader<Destination>(decoding: Legacy.self, timestampPolicy: .useKnownOrigin(origin)) { _ in
            mapped.hit(); return .init(url: URL(string: "sample://app/detail/42")!, gatedRoute: .detail("42"), plan: .init(state: .rootStack(path: [])))
        }
        let reader = try codec(legacy: legacy)
        let old = RouterLegacyPendingLinkEnvelope(schemaVersion: 1, originatedAt: origin, lastObservedAt: origin,
            link: PendingRouterLink<Legacy>(url: URL(string: "sample://app/detail/42")!, gatedRoute: .detail("42"), plan: .init(state: .rootStack(path: []))))
        let oldBytes = try JSONEncoder().encode(old)
        let oldObject = try JSONSerialization.jsonObject(with: oldBytes)
        var object = try #require(oldObject as? [String: Any])
        for key in ["formatVersion", "schemaID", "payload"] {
            object[key] = NSNull()
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try reader.decode(data, now: origin) }
            object.removeValue(forKey: key)
        }
        #expect(mapped.count == 0)
        _ = try reader.decode(JSONEncoder().encode(old), now: origin)
        #expect(mapped.count == 1)
    }

    @Test("Unknown-age legacy files need explicit fixed-origin policy")
    func explicitLegacyTimestampPolicy() throws {
        let old = RouterLegacyPendingLinkEnvelope(schemaVersion: 1, originatedAt: nil, lastObservedAt: nil,
            link: PendingRouterLink<Legacy>(url: URL(string: "sample://app/detail/42")!, gatedRoute: .detail("42"), plan: .init(state: .rootStack(path: []))))
        let bytes = try JSONEncoder().encode(old)
        let reject = RouterPendingLinkCodec<Legacy>()
        #expect(throws: RouterPendingLinkLifetimeFailure(code: .missingOriginTimestamp)) { try reject.decode(bytes, now: origin) }
        let known = RouterPendingLinkCodec<Legacy>(legacyTimestampPolicy: .useKnownOrigin(origin))
        #expect(try known.decode(bytes, now: origin).originatedAt == origin)
        #expect(throws: RouterPendingLinkLifetimeFailure(code: .expired)) { try known.decode(bytes, now: origin.addingTimeInterval(86_400)) }
    }

    @Test("Saving and driver replacement preserve origin; expiry and clock reversal precede resume")
    @MainActor
    func lifetimeAcrossSavesAndRestart() async throws {
        let clock = Clock(origin)
        let storage = MemoryStorage()
        let slot = RouterPendingLinkSlot<Destination>()
        let codec = try codec(lifetime: .seconds(100))
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: codec, now: { clock.date })
        _ = try await driver.submit(link())
        clock.advance(40)
        try await driver.save()
        let replacement = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: codec, now: { clock.date })
        clock.advance(30)
        try await replacement.save()
        let storedData = try storage.load()
        let data = try #require(storedData)
        #expect(try codec.decode(data, now: clock.date).originatedAt == origin)
        let restoredSlot = RouterPendingLinkSlot<Destination>()
        let restored = RouterPendingLinkPersistenceDriver(slot: restoredSlot, storage: storage, codec: codec, now: { clock.date })
        _ = try await restored.restore()
        clock.advance(30)
        let store = RouterStore<Destination>()
        await #expect(throws: RouterPendingLinkLifetimeFailure(code: .expired)) { _ = try await restored.resume(on: store) }
        guard case .completed(_, .rejected(_, _, _, .pendingLinkLifetime(let failure))) = await restoredSlot.resume(on: store) else {
            Issue.record("Direct slot continuation must also enforce persisted lifetime"); return
        }
        #expect(failure.code == .expired)
        #expect(store.revision == 0)
        #expect(try storage.load() == data)
        clock.advance(-40)
        await #expect(throws: RouterPendingLinkLifetimeFailure(code: .clockReversed)) { try await restored.save() }
        #expect(try storage.load() == data)
    }

    @Test("Explicit lifetime opt-out still rejects time reversal")
    func lifetimeOptOut() throws {
        let codec = try codec(lifetime: nil)
        let data = try encoded(codec)
        #expect(try codec.decode(data, now: origin.addingTimeInterval(1_000_000)).originatedAt == origin)
        #expect(throws: RouterPendingLinkLifetimeFailure(code: .clockReversed)) { try codec.decode(data, now: origin.addingTimeInterval(-1)) }
    }

    @Test("Slow graph restore cannot replace newer slot intent")
    @MainActor
    func staleRestore() async throws {
        let storage = BlockingLoad(try encoded())
        let slot = RouterPendingLinkSlot<Destination>()
        let fixed = origin
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: try codec(), now: { fixed })
        var starts = storage.started.makeAsyncIterator()
        let loading = Task { try await driver.restore() }
        _ = await starts.next()
        _ = slot.submit(link("new"))
        storage.release()
        #expect(try await loading.value == .supersededByNewerInMemoryLink)
        #expect(slot.pending?.gatedRoute == .detail("new"))
    }

    @Test("Cancel queued behind graph load removes data and prevents resurrection")
    @MainActor
    func cancelDuringRestore() async throws {
        let storage = BlockingLoad(try encoded())
        let slot = RouterPendingLinkSlot<Destination>()
        let fixed = origin
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: try codec(), now: { fixed })
        var starts = storage.started.makeAsyncIterator()
        let loading = Task { try await driver.restore() }
        _ = await starts.next()
        let (statusEvents, statusContinuation) = AsyncStream<Void>.makeStream()
        var statusIterator = statusEvents.makeAsyncIterator()
        withObservationTracking { _ = driver.status } onChange: { statusContinuation.yield() }
        let cancelling = Task { try await driver.cancel() }
        _ = await statusIterator.next()
        storage.release()
        await #expect(throws: CancellationError.self) { _ = try await loading.value }
        _ = try await cancelling.value
        #expect(slot.pending == nil)
        #expect(!storage.hasData)
    }
    @Test("Pending migration outputs are bounded before the next hop or app decode")
    func migrationsAreAdjacentAndBounded() throws {
        let calls = Calls()
        let second = Calls()
        let base = try encoded()
        let older = try mutate(base) { envelope, _ in envelope.schemaVersion = 5 }
        let oversized = try codec(calls: calls, migrations: [
            .init(from: 5, to: 6) { _ in Data(repeating: 32, count: 2 * 1024 * 1024 + 1) },
            .init(from: 6, to: 7) { data in second.hit(); return data },
        ])
        #expect(throws: (any Error).self) { try oversized.decode(older, now: origin) }
        #expect(second.count == 0)
        #expect(calls.count == 0)
        let valid = try codec(calls: calls, migrations: [.init(from: 5, to: 6) { $0 }, .init(from: 6, to: 7) { $0 }])
        #expect(try valid.decode(older, now: origin).originatedAt == origin)
        #expect(calls.count == 3)
        #expect(throws: RouterPendingLinkPersistenceError.invalidMigration(from: 5, to: 7)) {
            try codec(migrations: [.init(from: 5, to: 7) { $0 }])
        }
    }

    @Test("Malformed nested graph cannot enter even a standalone target decoder")
    func invalidPlanIsRejectedFirst() throws {
        let calls = Calls()
        let malformed = try mutate(encoded()) { _, payload in
            var envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: payload.plan)
            var graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: envelope.payload)
            graph.rootNodeID = "missing-node"
            envelope.payload = try JSONEncoder().encode(graph)
            payload.plan = try JSONEncoder().encode(envelope)
        }
        #expect(throws: (any Error).self) { try codec(calls: calls).decode(malformed, now: origin) }
        #expect(calls.count == 0)
    }

    @Test("Actual pending-file read/write caps preserve original bytes")
    func fileBoundsPreserveData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-bounds-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try encoded()
        try bytes.write(to: url)
        let bounded = try RouterFilePendingLinkStorage(fileURL: url, maximumByteCount: bytes.count - 1)
        #expect(throws: (any Error).self) { try bounded.load() }
        #expect(throws: (any Error).self) { try bounded.save(bytes) }
        #expect(try Data(contentsOf: url) == bytes)
        let exact = try RouterFilePendingLinkStorage(fileURL: url, maximumByteCount: bytes.count)
        #expect(try exact.load() == bytes)
    }

    @Test("A queued cancel finishes after an already-started save without resurrection")
    @MainActor
    func cancelAfterWriteStarts() async throws {
        let storage = BlockingSave()
        let slot = RouterPendingLinkSlot<Destination>()
        let fixed = origin
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: try codec(), now: { fixed })
        var starts = storage.started.makeAsyncIterator()
        let saving = Task { try await driver.submit(link()) }
        _ = await starts.next()
        let (reservations, continuation) = AsyncStream<RouterDurabilityReservation>.makeStream()
        var iterator = reservations.makeAsyncIterator()
        let cancelling = Task {
            try await RouterDurabilityTestSupport.withReservationObserver({ continuation.yield($0) }) {
                try await driver.cancel()
            }
        }
        let reservation = await iterator.next()
        #expect(reservation?.command == .remove)
        storage.release()
        await #expect(throws: CancellationError.self) { _ = try await saving.value }
        _ = try await cancelling.value
        #expect(slot.pending == nil)
        #expect(try storage.load() == nil)
        try await driver.save()
        #expect(try storage.load() == nil)
    }

    @Test("Restored non-Codable intent rechecks current origin, route meaning, and authorization")
    @MainActor
    func freshAdmissionBeforeResume() async throws {
        let slot = RouterPendingLinkSlot<Destination>()
        let fixed = origin
        let storage = MemoryStorage(try encoded())
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: try codec(), now: { fixed })
        _ = try await driver.restore()
        let authorizations = Calls()
        func pipeline(host: String = "app", target: String = "42", allowed: Bool) -> RouterLinkPipeline<Destination> {
            let matcher = DeepLinkMatcher<Destination> { DeepLinkMapping("/detail/:id") { _ in .detail(target) } }
            return .init(originPolicy: .allowlisted(schemes: ["sample"], hosts: [host]), matcher: matcher,
                authenticationPolicy: .required(shouldRequireAuthentication: { _ in true }, isAuthenticated: {
                    authorizations.hit(); return allowed
                }))
        }
        let store = RouterStore<Destination>()
        guard case .rejected = try await driver.resume(on: store, using: pipeline(host: "other", allowed: true)) else {
            Issue.record("Stored URL must pass the current origin allowlist"); return
        }
        #expect(authorizations.count == 0)
        guard case .rejected(_, .authorization(let changed)) = try await driver.resume(on: store, using: pipeline(target: "changed", allowed: true)) else {
            Issue.record("Changed route meaning must not reuse persisted intent"); return
        }
        #expect(changed.code == .intentChanged)
        #expect(authorizations.count == 0)
        guard case .pending = try await driver.resume(on: store, using: pipeline(allowed: false)) else {
            Issue.record("Current denied authentication must retain the intent"); return
        }
        #expect(slot.pending != nil)
        #expect(store.revision == 0)
        guard case .completed(_, .applied) = try await driver.resume(on: store, using: pipeline(allowed: true)) else {
            Issue.record("Freshly admitted intent should apply exactly once"); return
        }
        #expect(slot.pending == nil)
        #expect(store.revision == 1)
        #expect(try storage.load() == nil)
        #expect(authorizations.count == 2)
    }

    @Test("Durable intent cannot commit after expiring during policy suspension")
    @MainActor
    func expiryAcrossPolicyAwait() async throws {
        let clock = Clock(origin)
        let storage = MemoryStorage()
        let slot = RouterPendingLinkSlot<Destination>()
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage,
            codec: try codec(lifetime: .seconds(10)), now: { clock.date })
        _ = try await driver.submit(link())
        let originalBytes = try storage.load()
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = try RouterStore<Destination>(configuration: .init(policies: [
            RouterPolicy(name: "suspend") { _ in
                for await _ in gate { break }
                return .allow
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let resuming = Task { try await driver.resume(on: store) }
        guard case .started = await events.next() else {
            continuation.finish(); Issue.record("Expected policy admission to begin"); return
        }
        clock.advance(11)
        continuation.yield()
        continuation.finish()
        await #expect(throws: RouterPendingLinkLifetimeFailure(code: .expired)) { _ = try await resuming.value }
        #expect(store.revision == 0)
        #expect(slot.pending != nil)
        #expect(try storage.load() == originalBytes)
    }
    @Test("Outer pending migration can update targets and an older nested plan without a graph migration")
    func outerMigrationUpdatesTargetsAndPlan() throws {
        let calls = Calls()
        let migrationCalls = Calls()
        let older = try mutate(encoded()) { envelope, payload in
            envelope.schemaVersion = 6
            payload.gatedRoute.stableKey = "old.detail"
            payload.gatedRoute.payloadVersion = 1
            payload.matchedRoute?.stableKey = "old.detail"
            payload.matchedRoute?.payloadVersion = 1
            var plan = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: payload.plan)
            plan.schemaVersion = 6
            var graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: plan.payload)
            for index in graph.routes.indices {
                graph.routes[index].payload.stableKey = "old.detail"
                graph.routes[index].payload.payloadVersion = 1
            }
            plan.payload = try JSONEncoder().encode(graph)
            payload.plan = try JSONEncoder().encode(plan)
        }
        // Control: structure-only screening must reach the explicit missing
        // outer migration before any decoder for these old keys can execute.
        let missing = try codec(calls: calls)
        #expect(throws: RouterPendingLinkPersistenceError.missingMigration(from: 6, current: 7)) {
            try missing.decode(older, now: origin)
        }
        #expect(calls.count == 0)
        let migration = RouterPendingLinkMigration(from: 6, to: 7) { data in
            migrationCalls.hit()
            var payload = try JSONDecoder().decode(RouterPendingLinkGraphPayload.self, from: data)
            payload.gatedRoute.stableKey = "stable.detail"
            payload.gatedRoute.payloadVersion = 3
            payload.matchedRoute?.stableKey = "stable.detail"
            payload.matchedRoute?.payloadVersion = 3
            var plan = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: payload.plan)
            plan.schemaVersion = 7
            var graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: plan.payload)
            for index in graph.routes.indices {
                graph.routes[index].payload.stableKey = "stable.detail"
                graph.routes[index].payload.payloadVersion = 3
            }
            plan.payload = try JSONEncoder().encode(graph)
            payload.plan = try JSONEncoder().encode(plan)
            return try JSONEncoder().encode(payload)
        }
        let migrated = try codec(calls: calls, migrations: [migration]).decode(older, now: origin)
        #expect(migrationCalls.count == 1)
        #expect(calls.count == 3)
        #expect(migrated.link.gatedRoute == .detail("42"))
        #expect(migrated.link.matchedRoute == .detail("42"))
        #expect(migrated.link.plan == link().plan)
        #expect(migrated.link.requiresRevalidation)
        #expect(migrated.originatedAt == origin)
    }

    @Test("Nested graph migration runs once after all outer pending migration boundaries")
    func nestedGraphMigrationRunsOnce() throws {
        let calls = Calls()
        let graphCalls = Calls()
        let outerCalls = Calls()
        let older = try mutate(encoded()) { envelope, payload in
            envelope.schemaVersion = 5
            var plan = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: payload.plan)
            plan.schemaVersion = 6
            var graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: plan.payload)
            for index in graph.routes.indices {
                graph.routes[index].payload.stableKey = "old.detail"
                graph.routes[index].payload.payloadVersion = 1
            }
            plan.payload = try JSONEncoder().encode(graph)
            payload.plan = try JSONEncoder().encode(plan)
        }
        let outer: [RouterPendingLinkMigration] = [
            .init(from: 5, to: 6) { data in outerCalls.hit(); return data },
            .init(from: 6, to: 7) { data in outerCalls.hit(); return data },
        ]
        let graph = RouterGraphSnapshotMigration(from: 6, to: 7) { data in
            graphCalls.hit()
            var snapshot = try JSONDecoder().decode(RouterGraphSnapshot.self, from: data)
            for index in snapshot.routes.indices {
                snapshot.routes[index].payload.stableKey = "stable.detail"
                snapshot.routes[index].payload.payloadVersion = 3
            }
            return try JSONEncoder().encode(snapshot)
        }
        let migrated = try codec(calls: calls, migrations: outer, graphMigrations: [graph]).decode(older, now: origin)
        #expect(outerCalls.count == 2)
        #expect(graphCalls.count == 1)
        #expect(calls.count == 3)
        #expect(migrated.link.plan == link().plan)
        #expect(migrated.originatedAt == origin)
    }
}
