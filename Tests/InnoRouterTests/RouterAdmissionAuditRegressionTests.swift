import Foundation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

@Suite("Independent resource admission audit regressions", .timeLimit(.minutes(1)))
@MainActor
struct RouterAdmissionAuditRegressionTests {
    private struct Screen: Route, Codable {
        static let encodes = Mutex(0)
        static let decodes = Mutex(0)
        let value: String
        init(_ value: String) { self.value = value }
        init(from decoder: any Decoder) throws {
            Self.decodes.withLock { $0 += 1 }
            value = try decoder.singleValueContainer().decode(String.self)
        }
        func encode(to encoder: any Encoder) throws {
            Self.encodes.withLock { $0 += 1 }
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
    private func record(matched: Bool = true, value: String = "abc") -> RouterDurablePendingLink<Screen> {
        .init(link: .init(
            url: URL(string: "test://router/screen")!, gatedRoute: Screen(value), plan: .init(state: .rootStack),
            matchedRoute: matched ? Screen(value) : nil
        ), originatedAt: Date(timeIntervalSince1970: 100), lastObservedAt: Date(timeIntervalSince1970: 100))
    }

    @Test("Legacy writer rejects combined intent routes before any app encoder")
    func pendingCombinedRouteCount() throws {
        Screen.encodes.withLock { $0 = 0 }
        let codec = RouterPendingLinkCodec<Screen>(limits: try .init(maximumRoutes: 1))
        #expect(throws: RouterResourceLimitFailure.self) { try codec.encode(record()) }
        #expect(Screen.encodes.withLock { $0 } == 0)
        let control = record(matched: false)
        let data = try codec.encode(control)
        #expect(try codec.decode(data, now: control.lastObservedAt).link.gatedRoute == control.link.gatedRoute)
    }

    @Test("Legacy writer applies the reader's exact per-route JSON byte admission")
    func pendingRouteBytes() throws {
        let codec = RouterPendingLinkCodec<Screen>(limits: try .init(maximumRoutePayloadBytes: 4))
        #expect(throws: RouterPendingLinkPersistenceError.self) { try codec.encode(record(matched: false)) }
        let control = record(matched: false, value: "x")
        let data = try codec.encode(control)
        #expect(try codec.decode(data, now: control.lastObservedAt).link.gatedRoute == Screen("x"))
    }

    @Test("Legacy writer uses one aggregate route-payload byte cap")
    func pendingTotalRouteBytes() throws {
        let codec = RouterPendingLinkCodec<Screen>(limits: try .init(maximumPayloadBytes: 6))
        #expect(throws: RouterPendingLinkPersistenceError.self) { try codec.encode(record()) }
        let control = record(matched: false)
        let data = try codec.encode(control)
        #expect(try codec.decode(data, now: control.lastObservedAt).link.gatedRoute == Screen("abc"))
    }

    @Test("History projects all paths admitted by a larger owner without a default-limit trap", arguments: [false, true])
    func largerHistoryOwner(unlimited: Bool) async throws {
        let budget: RouterResourceBudget = unlimited ? .unlimited : .init(snapshot: try .init(maximumStackPath: 257))
        let paths = (0..<257).map { Screen(String($0)) }
        let initial = try RouterStore<Screen>(initialPath: paths, configuration: .init(resourceBudget: budget))
        let initialHistory = RouterHistory(store: initial)
        #expect(initialHistory.currentEntry.navigationState == initial.state)
        initialHistory.stop()
        let store = try RouterStore<Screen>(initialPath: Array(paths.prefix(256)), configuration: .init(resourceBudget: budget))
        let history = RouterHistory(store: store)
        guard case .applied = await store.perform(.push(paths[256])) else {
            Issue.record("The owner's explicit 257-route path must remain admitted")
            return
        }
        #expect(history.currentEntry.navigationState == .rootStack(path: paths))
        #expect(store.revision == 1)
        history.stop()
    }

    @Test("Legacy depth cannot be bypassed through a graph fallback adapter")
    func legacyDepthOwnerAcrossFormats() async throws {
        let legacy = try RouterSnapshotCodec<Screen>(currentVersion: 17)
        let target = RouterState<Screen>.rootStack(path: [Screen("screen")])
        let bytes = try legacy.encode(target)
        Screen.decodes.withLock { $0 = 0 }
        let graph = try RouterGraphSnapshotCodec<Screen>(
            schemaID: "depth", schemaVersion: 1,
            routes: .init(supportedPayloadVersions: ["screen": 1], encode: {
                .init(stableKey: "screen", payloadVersion: 1, data: Data($0.value.utf8))
            }, decode: { Screen(String(decoding: $0.data, as: UTF8.self)) }),
            legacyAdapter: .init(codec: legacy)
        )
        let store = try RouterStore<Screen>(configuration: .init(resourceBudget: .init(legacyJSONDepth: 1)))
        await #expect(throws: RouterSnapshotError.self) { try await store.restore(from: bytes, using: legacy) }
        await #expect(throws: RouterGraphSnapshotError.self) { try await store.restore(from: bytes, using: graph) }
        #expect(Screen.decodes.withLock { $0 } == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(try graph.decode(bytes) == target)
        #expect(Screen.decodes.withLock { $0 } == 1)
    }
    @Test("Pending shared budget preserves the owner's legacy depth through both formats")
    func pendingLegacyOwnerDepth() throws {
        let value = record(matched: false)
        let bytes = try RouterPendingLinkCodec<Screen>().encode(value)
        Screen.decodes.withLock { $0 = 0 }
        let budget = RouterResourceBudget(legacyJSONDepth: 1)
        let legacy = try RouterPendingLinkCodec<Screen>(resourceBudget: budget)
        #expect(throws: RouterPendingLinkPersistenceError.self) { try legacy.decode(bytes, now: value.lastObservedAt) }
        let graph = try RouterGraphSnapshotCodec<Screen>(
            schemaID: "pending-depth", schemaVersion: 1,
            routes: .init(supportedPayloadVersions: ["screen": 1], encode: {
                .init(stableKey: "screen", payloadVersion: 1, data: Data($0.value.utf8))
            }, decode: { Screen(String(decoding: $0.data, as: UTF8.self)) })
        )
        let pending = try RouterPendingLinkCodec(graphCodec: graph, resourceBudget: budget, legacyReader: .init())
        #expect(throws: RouterPendingLinkPersistenceError.self) { try pending.decode(bytes, now: value.lastObservedAt) }
        #expect(Screen.decodes.withLock { $0 } == 0)
    }

    @Test("Invalid pending budget and raw negative lifetime fail explicitly")
    func pendingInvalidConfiguration() throws {
        #expect(throws: RouterResourceLimitFailure.self) {
            try RouterPendingLinkCodec<Screen>(resourceBudget: .init(durablePendingLifetime: .seconds(-1)))
        }
        let raw = RouterPendingLinkCodec<Screen>(lifetime: .seconds(-1))
        #expect(raw.lifetime == .seconds(-1))
        #expect(throws: RouterResourceLimitFailure.self) { try raw.encode(record()) }
    }
}
