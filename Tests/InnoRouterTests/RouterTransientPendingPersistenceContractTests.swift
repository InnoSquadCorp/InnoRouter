import Foundation
import Synchronization
import Testing
@testable import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

@Suite("Transient pending and partial restoration", .serialized)
struct RouterTransientPendingPersistenceContractTests {
    private struct Destination: Route, Codable {
        static let calls = Mutex((encode: 0, decode: 0))
        let value: Int
        init(_ value: Int) { self.value = value }
        init(from decoder: any Decoder) throws {
            Self.calls.withLock { $0.decode += 1 }
            value = try decoder.singleValueContainer().decode(Int.self)
        }
        func encode(to encoder: any Encoder) throws {
            Self.calls.withLock { $0.encode += 1 }
            var field = encoder.singleValueContainer()
            try field.encode(value)
        }
    }
    private final class Storage: RouterPendingLinkStorage {
        let bytes: Mutex<Data?>
        let writes = Mutex(0)
        let removes = Mutex(0)
        init(_ data: Data) { bytes = Mutex(data) }
        func load() throws -> Data? { bytes.withLock { $0 } }
        func save(_ data: Data) throws { writes.withLock { $0 += 1 }; bytes.withLock { $0 = data } }
        func remove() throws { removes.withLock { $0 += 1 }; bytes.withLock { $0 = nil } }
    }
    private func reset() { Destination.calls.withLock { $0 = (0, 0) } }
    private var encodes: Int { Destination.calls.withLock { $0.encode } }
    private var decodes: Int { Destination.calls.withLock { $0.decode } }
    private let now = Date(timeIntervalSince1970: 1_000)
    private func state(_ title: String = "Private") throws -> RouterState<Destination> {
        try .init(root: .container(.init(style: .tabs, selection: "a", branches: [
            .init(id: "a", node: .stack(path: [.init(1)])),
            .init(id: "b", node: .stack(presentationFamily: .confirmationDialog(.init(content: .init(
                title: title, actions: [.init(id: "ok", label: "Private")]
            )))))
        ])))
    }
    private func record(_ state: RouterState<Destination>) -> RouterDurablePendingLink<Destination> {
        .init(link: .init(url: URL(string: "https://example.test/path")!, gatedRoute: .init(7), plan: .init(state: state),
                         matchedRoute: .init(8)), originatedAt: now, lastObservedAt: now)
    }
    private func graph(_ policy: RouterTransientPresentationPersistencePolicy = .reject,
                       limits: RouterGraphSnapshotLimits = .provisional,
                       reader: RouterLegacyPendingLinkReader<Destination>? = nil) throws -> RouterPendingLinkCodec<Destination> {
        let routes = try RouterGraphRouteCodec<Destination>(supportedPayloadVersions: ["route": 1], encode: { route in
            Destination.calls.withLock { $0.encode += 1 }
            return .init(stableKey: "route", payloadVersion: 1, data: Data([UInt8(route.value)]))
        }, decode: { payload in
            Destination.calls.withLock { $0.decode += 1 }
            return .init(Int(payload.data.first ?? 0))
        })
        return try .init(graphCodec: .init(schemaID: "test", schemaVersion: 1, routes: routes, limits: limits,
                                         transientPresentations: policy), legacyReader: reader)
    }
    private func forbiddenLegacy() throws -> Data {
        let codec = RouterPendingLinkCodec<Destination>()
        let data = try codec.encode(record(.rootStack(path: [.init(1)])))
        var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var link = try #require(envelope["link"] as? [String: Any])
        var plan = try #require(link["plan"] as? [String: Any])
        var state = try #require(plan["state"] as? [String: Any])
        state["root"] = ["stack": ["_0": ["path": [1], "presentationFamily": ["alert": [:]]]]]
        plan["state"] = state; link["plan"] = plan; envelope["link"] = link
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
    private func forbiddenGraph() throws -> Data {
        let data = try graph().encode(record(.rootStack(path: [.init(1)])))
        var envelope = try JSONDecoder().decode(RouterPendingLinkGraphEnvelope.self, from: data)
        var payload = try JSONDecoder().decode(RouterPendingLinkGraphPayload.self, from: envelope.payload)
        var plan = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: payload.plan)
        var dto = try #require(JSONSerialization.jsonObject(with: plan.payload) as? [String: Any])
        var nodes = try #require(dto["nodes"] as? [[String: Any]])
        var stack = try #require(nodes[0]["stack"] as? [String: Any])
        stack["alert"] = NSNull(); nodes[0]["stack"] = stack; dto["nodes"] = nodes
        plan.payload = try JSONSerialization.data(withJSONObject: dto)
        payload.plan = try JSONEncoder().encode(plan)
        envelope.payload = try JSONEncoder().encode(payload)
        return try JSONEncoder().encode(envelope)
    }

    @Test func aggregateEncodersRejectBeforeGatedMatchedOrPlanRoute() throws {
        let record = record(try state())
        reset()
        #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.transientPresent)) {
            try RouterPendingLinkCodec<Destination>().encode(record)
        }
        #expect(encodes == 0)
        #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.transientPresent)) { try graph().encode(record) }
        #expect(encodes == 0)
    }

    @Test func omitRoundtripPreservesIntentAndFullSourceBudget() throws {
        let original = record(try state())
        let expected = try original.link.plan.state.preparingTransientPersistence(.omit)
        let codecs = [RouterPendingLinkCodec<Destination>(transientPresentations: .omit),
                      try RouterPendingLinkCodec<Destination>(resourceBudget: .init(), transientPresentations: .omit),
                      try graph(.omit)]
        for codec in codecs {
            let restored = try codec.decode(codec.encode(original), now: now)
            #expect(restored.link.plan.state == expected)
            #expect(restored.link.gatedRoute == original.link.gatedRoute)
            #expect(restored.link.matchedRoute == original.link.matchedRoute)
            #expect(restored.link.requiresRevalidation)
        }
        #expect(original.link.plan.state != expected)
        let limits = try RouterGraphSnapshotLimits(maximumPayloadBytes: 32)
        let oversized = record(try state(String(repeating: "x", count: 40)))
        reset()
        #expect(throws: (any Error).self) { try graph(.omit, limits: limits).encode(oversized) }
        #expect(throws: RouterResourceLimitFailure.self) {
            try RouterPendingLinkCodec<Destination>(limits: limits, transientPresentations: .omit).encode(oversized)
        }
        #expect(encodes == 0)
    }

    @Test func bothInputsRejectBeforeAnyGatedMatchedOrPlanDecoder() throws {
        let legacy = try forbiddenLegacy()
        let graphData = try forbiddenGraph()
        reset()
        #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.unsupportedRestoration)) {
            try RouterPendingLinkCodec<Destination>(transientPresentations: .omit).decode(legacy, now: now)
        }
        #expect(decodes == 0)
        #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.unsupportedRestoration)) {
            try graph(.omit).decode(graphData, now: now)
        }
        #expect(decodes == 0)
    }

    @Test func legacyMappingCannotReturnTransientDespiteOmit() throws {
        let mapped = record(try state()).link
        let reader = RouterLegacyPendingLinkReader<Destination>(decoding: Destination.self,
            timestampPolicy: .rejectMissingTimestamp, transform: { _ in mapped })
        let bytes = try RouterPendingLinkCodec<Destination>().encode(record(.rootStack(path: [.init(1)])))
        reset()
        #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.unsupportedRestoration)) {
            try graph(.omit, reader: reader).decode(bytes, now: now)
        }
        #expect(encodes == 0)
        #expect(decodes == 3)
    }

    @Test @MainActor func failedLoadLeavesStoredBytesAndSlotUntouched() async throws {
        let data = try forbiddenLegacy()
        let storage = Storage(data)
        let slot = RouterPendingLinkSlot<Destination>()
        let fixedNow = now
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage,
            codec: RouterPendingLinkCodec<Destination>(), now: { fixedNow })
        await #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.unsupportedRestoration)) { try await driver.restore() }
        #expect(storage.bytes.withLock { $0 } == data)
        #expect(storage.writes.withLock { $0 } == 0)
        #expect(storage.removes.withLock { $0 } == 0)
    }

    @Test @MainActor func failedSavePreservesOriginalBytesAndLivePendingIntent() async throws {
        let data = Data("original bytes".utf8)
        let link = record(try state()).link
        let codecs = [RouterPendingLinkCodec<Destination>(), try graph()]
        for codec in codecs {
            let storage = Storage(data)
            let slot = RouterPendingLinkSlot(link)
            let fixedNow = now
            let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage, codec: codec, now: { fixedNow })
            reset()
            await #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.transientPresent)) { try await driver.save() }
            #expect(storage.bytes.withLock { $0 } == data)
            #expect(storage.writes.withLock { $0 } == 0)
            #expect(storage.removes.withLock { $0 } == 0)
            #expect(slot.pending == link)
            #expect(encodes == 0)
        }
    }

    @Test @MainActor func partialRestorationRejectsBeforeValidatorOrReservation() async throws {
        let calls = Mutex(0)
        let operations = RouterOperationRegistry(maximumCount: 1)
        await #expect(throws: RouterPartialRestorationError.transientPresentation(.unsupportedRestoration)) {
            try await preparePartialRestoration(state(), validator: .init { _, _ in
                calls.withLock { $0 += 1 }; return .keep
            }, operations: operations, timeout: nil, sleep: { _ in })
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(operations.activeCount == 0)
    }
}
