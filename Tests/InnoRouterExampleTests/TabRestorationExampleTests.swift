import Foundation
import Testing

import InnoRouter
@testable import InnoRouterTabRestorationExample

@Suite("Copyable tab restoration example")
@MainActor
struct TabRestorationExampleTests {
    @Test("A previous catalog is upgraded, saved, and reopened through the example session")
    func upgradeAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "navigation.json")
        try await TabRestorationExampleSession.writePreviousVersionSnapshot(to: url)
        let session = try TabRestorationExampleSession(snapshotURL: url)
        defer { session.driver.stop() }

        let activation = try await session.driver.activate()
        guard case .restored(let outcome) = activation,
              case .applied = outcome.transition,
              case .container(let tabs) = session.store.state.root else {
            Issue.record("Expected the example to commit the reconciled snapshot")
            return
        }
        #expect(tabs.selection == "home")
        #expect(tabs.branches.map(\.id) == ["home", "settings", "legacy"])
        #expect(session.store.scope(at: ["home"]).node == .stack(path: [.detail(id: "saved-home")]))
        #expect(session.store.scope(at: ["legacy"]).node == .stack(path: [.detail(id: "saved-legacy")]))
        #expect(session.store.scope(at: ["settings"]).node == .stack())
        _ = try RouterTabHost(store: session.store, catalog: session.catalog, allowingOrphanedBranches: true)

        guard case .applied = await session.store.perform(.select("settings")),
              case .applied = await session.store.scope(at: ["settings"]).perform(.push(.detail(id: "new"))) else {
            Issue.record("The newly added tab must support real navigation")
            return
        }
        try await session.driver.save()
        session.driver.stop()

        let reopened = try TabRestorationExampleSession(snapshotURL: url)
        defer { reopened.driver.stop() }
        guard case .restored(let restored) = try await reopened.driver.activate(),
              case .applied = restored.transition else {
            Issue.record("Expected a new example session to restore the saved file")
            return
        }
        #expect(reopened.store.state == session.store.state)
        // Await a final save so all demo I/O is finished before deleting the file.
        try await reopened.driver.save()
    }

    @Test("A first launch with no file keeps the current catalog")
    func noSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try TabRestorationExampleSession(snapshotURL: directory.appending(path: "navigation.json"))
        defer { session.driver.stop() }
        let initial = session.store.state
        #expect(try await session.driver.activate() == .noSnapshot)
        #expect(session.store.state == initial)
        #expect(session.driver.status == .active)
    }

    @Test("An unreadable snapshot is surfaced without replacing the file or state")
    func invalidSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "navigation.json")
        let invalid = Data("invalid snapshot".utf8)
        try invalid.write(to: url)
        let session = try TabRestorationExampleSession(snapshotURL: url)
        defer { session.driver.stop() }
        let initial = session.store.state
        await #expect(throws: (any Error).self) { try await session.driver.activate() }
        guard case .failed = session.driver.status else {
            Issue.record("The UI must be able to observe the restore failure")
            return
        }
        #expect(session.store.state == initial)
        #expect(try Data(contentsOf: url) == invalid)
    }
}
