import Foundation
import Testing

import InnoRouterCore

@Suite("RouterSnapshot")
struct RouterSnapshotTests {
    private enum RouteFixture: String, Route, Codable {
        case home
        case detail
        case settings
    }

    private struct LegacyState: Codable, Sendable {
        let routes: [RouteFixture]
    }

    @Test("Encoding is deterministic and preserves the complete state")
    func deterministicRoundTrip() throws {
        let state = try RouterState<RouteFixture>(
            root: .stack(path: [.home, .detail]),
            windows: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, route: .settings)],
            immersiveSpace: .init(id: "studio", route: .detail)
        )
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 2)

        let first = try codec.encode(state)
        let second = try codec.encode(state)

        #expect(first == second)
        #expect(try codec.decode(first) == state)
    }

    @Test("Adjacent migrations run in schema order before typed decode")
    func migrationChain() throws {
        let oldPayload = try JSONEncoder().encode(
            RouterState<RouteFixture>.rootStack(path: [.home])
        )
        let oldEnvelope = RouterSnapshotEnvelope(schemaVersion: 1, payload: oldPayload)
        let oldData = try JSONEncoder().encode(oldEnvelope)
        let codec = try RouterSnapshotCodec<RouteFixture>(
            currentVersion: 2,
            migrations: [
                RouterSnapshotMigration(from: 1, to: 2) { payload in
                    let text = String(decoding: payload, as: UTF8.self)
                    return Data(text.replacingOccurrences(of: "home", with: "detail").utf8)
                }
            ]
        )

        let state = try codec.decode(oldData)

        #expect(state.root == .stack(path: [.detail]))
    }

    @Test("Typed migrations decode legacy payloads and encode the next schema")
    func typedMigration() throws {
        let payload = try JSONEncoder().encode(
            LegacyState(routes: [.home, .detail])
        )
        let data = try JSONEncoder().encode(
            RouterSnapshotEnvelope(schemaVersion: 1, payload: payload)
        )
        let codec = try RouterSnapshotCodec<RouteFixture>(
            currentVersion: 2,
            migrations: [
                .codable(
                    from: 1,
                    to: 2,
                    decoding: LegacyState.self
                ) { legacy in
                    RouterState<RouteFixture>.rootStack(path: legacy.routes)
                }
            ]
        )

        #expect(
            try codec.decode(data)
                == RouterState<RouteFixture>.rootStack(path: [.home, .detail])
        )
    }

    @Test("Future and migration-gap snapshots fail explicitly")
    func versionFailures() throws {
        let payload = try JSONEncoder().encode(RouterState<RouteFixture>.rootStack)
        let future = try JSONEncoder().encode(
            RouterSnapshotEnvelope(schemaVersion: 3, payload: payload)
        )
        let old = try JSONEncoder().encode(
            RouterSnapshotEnvelope(schemaVersion: 1, payload: payload)
        )
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 2)

        #expect(throws: RouterSnapshotError.futureVersion(snapshot: 3, current: 2)) {
            try codec.decode(future)
        }
        #expect(throws: RouterSnapshotError.missingMigration(from: 1, current: 2)) {
            try codec.decode(old)
        }
    }

    @Test("Malformed envelopes and invalid migration definitions are typed")
    func malformedInputs() throws {
        #expect(throws: RouterSnapshotError.invalidCurrentVersion(0)) {
            _ = try RouterSnapshotCodec<RouteFixture>(currentVersion: 0)
        }
        #expect(throws: RouterSnapshotError.invalidMigration(from: 1, to: 3)) {
            _ = try RouterSnapshotCodec<RouteFixture>(
                currentVersion: 3,
                migrations: [.init(from: 1, to: 3) { $0 }]
            )
        }
        #expect(throws: RouterSnapshotError.self) {
            _ = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1).decode(Data("not-json".utf8))
        }
    }

    @Test("Nonpositive snapshot versions fail before migration or payload decoding", arguments: [0, -1, Int.min])
    func invalidSnapshotVersion(version: Int) throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try JSONEncoder().encode(
            RouterSnapshotEnvelope(schemaVersion: version, payload: Data("invalid".utf8))
        )
        #expect(throws: RouterSnapshotError.invalidSnapshotVersion(version)) {
            try codec.decode(data)
        }
        #expect(try codec.decode(data, recovery: .use { _ in .rootStack }) == .recovered(
            state: .rootStack,
            reason: .invalidSnapshotVersion(version)
        ))
    }

    @Test("Migration definitions cannot exceed the current schema or overflow", arguments: [2, Int.max])
    func migrationAboveCurrentVersion(from: Int) {
        let to = from == Int.max ? Int.max : from + 1
        #expect(throws: RouterSnapshotError.invalidMigration(from: from, to: to)) {
            _ = try RouterSnapshotCodec<RouteFixture>(
                currentVersion: 2,
                migrations: [.init(from: from, to: to) { $0 }]
            )
        }
    }

    @Test("Recovery is explicit and reports the original typed failure")
    func explicitRecovery() throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let malformed = Data("not-json".utf8)

        let result = try codec.decode(
            malformed,
            recovery: .use { _ in .rootStack(path: [.home]) }
        )

        guard case .recovered(let state, let reason) = result else {
            Issue.record("Expected explicit recovery")
            return
        }
        #expect(state.root == .stack(path: [.home]))
        guard case .decodeEnvelope = reason else {
            Issue.record("Expected original envelope failure")
            return
        }
    }

    @Test("Invalid state is rejected before encoding and after payload decoding")
    func invalidState() throws {
        var state = RouterState<RouteFixture>.rootStack
        let duplicateID = UUID()
        state.windows = [
            .init(id: duplicateID, route: .home),
            .init(id: duplicateID, route: .detail),
        ]
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)

        #expect(throws: RouterSnapshotError.invalidState(.duplicateWindow)) {
            _ = try codec.encode(state)
        }

        let invalidPayload = try JSONEncoder().encode(state)
        let envelope = try JSONEncoder().encode(
            RouterSnapshotEnvelope(schemaVersion: 1, payload: invalidPayload)
        )
        #expect(throws: RouterSnapshotError.invalidState(.duplicateWindow)) {
            _ = try codec.decode(envelope)
        }
    }
}
