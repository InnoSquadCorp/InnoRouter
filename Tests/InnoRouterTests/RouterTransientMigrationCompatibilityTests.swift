import Foundation
import Synchronization
import Testing

import InnoRouterCore

@Suite("Transient screen legacy migration compatibility")
struct RouterTransientMigrationCompatibilityTests {
    private enum R: String, Route, Codable { case home }

    @Test("Explicit nil limits preserve raw non-JSON initial migration inputs", arguments: ["", "old format", "{"])
    func initialRawInput(_ legacy: String) throws {
        let calls = Mutex(0)
        let target = RouterState<R>.rootStack(path: [.home])
        let valid = try JSONEncoder().encode(target)
        let migration = RouterSnapshotMigration(from: 1, to: 2) { _ in
            calls.withLock { $0 += 1 }
            return valid
        }
        let input = try JSONEncoder().encode(RouterSnapshotEnvelope(schemaVersion: 1, payload: Data(legacy.utf8)))
        #expect(try RouterSnapshotCodec<R>(currentVersion: 2, migrations: [migration], limits: nil).decode(input) == target)
        #expect(calls.withLock { $0 } == 1)
        calls.withLock { $0 = 0 }
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<R>(currentVersion: 2, migrations: [migration]).decode(input)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("Explicit nil limits preserve raw intermediate migration formats", arguments: ["", "old format", "{"])
    func intermediateRawInput(_ legacy: String) throws {
        let calls = Mutex<[Int]>([])
        let target = RouterState<R>.rootStack(path: [.home])
        let valid = try JSONEncoder().encode(target)
        let input = try RouterSnapshotCodec<R>(currentVersion: 1).encode(target)
        let migrations: [RouterSnapshotMigration] = [
            .init(from: 1, to: 2) { _ in calls.withLock { $0.append(1) }; return Data(legacy.utf8) },
            .init(from: 2, to: 3) { _ in calls.withLock { $0.append(2) }; return valid },
        ]
        #expect(try RouterSnapshotCodec<R>(currentVersion: 3, migrations: migrations, limits: nil).decode(input) == target)
        #expect(calls.withLock { $0 } == [1, 2])
        calls.withLock { $0 = [] }
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<R>(currentVersion: 3, migrations: migrations).decode(input)
        }
        #expect(calls.withLock { $0 } == [1])
    }
}
