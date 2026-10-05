import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Graph DTO persistence through the canonical driver", .timeLimit(.minutes(1)))
@MainActor
struct RouterGraphPersistenceContractTests {
    private struct R: Route { let value: Int }
    private enum Legacy: Int, Route, Codable { case home = 1 }
    private enum Failure: Error { case invalidPayload }

    private func codec(legacyAdapter: RouterLegacySnapshotAdapter<R>? = nil) throws -> RouterGraphSnapshotCodec<R> {
        try .init(schemaID: "test.graph", schemaVersion: 3, routes: .init(
            supportedPayloadVersions: ["stable.screen": 1],
            encode: { route in
                .init(stableKey: "stable.screen", payloadVersion: 1, data: Data(String(route.value).utf8))
            },
            decode: { payload in
                guard let text = String(data: payload.data, encoding: .utf8), let value = Int(text) else {
                    throw Failure.invalidPayload
                }
                return R(value: value)
            }
        ), legacyAdapter: legacyAdapter)
    }

    private func file() throws -> (URL, RouterFileSnapshotStorage) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, RouterFileSnapshotStorage(fileURL: directory.appending(path: "state.json")))
    }

    @Test("Non-Codable routes restore through the same Store and replace equal ownership", arguments: [false, true])
    func directRestore(changed: Bool) async throws {
        let codec = try codec()
        let initial = RouterState<R>.rootStack(path: [.init(value: 1)])
        let target = changed ? RouterState<R>.rootStack(path: [.init(value: 2)]) : initial
        let store = try RouterStore(initialState: initial)
        let old = store.scope()
        let outcome = try await store.restore(from: codec.encode(target), using: codec)
        if changed {
            guard case .applied = outcome else { Issue.record("Expected graph application"); return }
        } else {
            guard case .unchanged = outcome else { Issue.record("Expected equal graph restoration"); return }
        }
        #expect(store.state == target)
        #expect(store.revision == (changed ? 1 : 0))
        #expect(old.node == nil)
        guard case .rejected = await old.perform(.push(.init(value: 9))) else {
            Issue.record("Persisted identity must not restore old runtime authority")
            return
        }
        let encoded = try await store.snapshot(using: codec)
        #expect(try codec.decode(encoded) == target)
    }

    @Test("Graph driver restores and writes actual bounded file storage without another Store")
    func fileDriverRoundTrip() async throws {
        let (directory, storage) = try file()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = try codec()
        let target = RouterState<R>.rootStack(path: [.init(value: 1)])
        try storage.save(codec.encode(target))
        let store = try RouterStore<R>(initialState: .rootStack)
        let driver = RouterRestorationDriver(store: store, graphCodec: codec, storage: storage)
        guard case .restored(let result) = try await driver.activate(), case .applied = result.transition else {
            Issue.record("Actual graph bytes must restore through canonical admission")
            return
        }
        #expect(store.state == target)
        #expect(store.revision == 1)
        guard case .applied = await store.perform(.push(.init(value: 2))) else {
            Issue.record("Expected normal navigation after activation")
            return
        }
        try await driver.save()
        let saved = try #require(try storage.load())
        #expect(try codec.decode(saved) == store.state)
        try await driver.removeSnapshot()
        #expect(try storage.load() == nil)
        driver.stop()
        #expect(store.state == .rootStack(path: [.init(value: 1), .init(value: 2)]))
        #expect(store.revision == 2)
    }

    @Test("Invalid graph and legacy envelopes never fall back or overwrite the original", arguments: [false, true])
    func decodeFailurePreservesOriginal(legacy: Bool) async throws {
        let (directory, storage) = try file()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = legacy
            ? try RouterSnapshotCodec<Legacy>(currentVersion: 17).encode(.rootStack(path: [.home]))
            : Data("{\"unknown\":1}".utf8)
        try storage.save(original)
        let store = try RouterStore<R>(initialState: .rootStack)
        let driver = RouterRestorationDriver(store: store, graphCodec: try codec(), storage: storage)
        await #expect(throws: RouterGraphSnapshotError.self) { try await driver.activate() }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(try storage.load() == original)
        driver.stop()
    }

    @Test("Driver authorization generation is fixed before the first worker suspension", arguments: [false, true])
    func activationGeneration(legacy: Bool) async throws {
        let (directory, storage) = try file()
        defer { try? FileManager.default.removeItem(at: directory) }
        if legacy {
            let codec = try RouterSnapshotCodec<Legacy>(currentVersion: 17)
            try storage.save(codec.encode(.rootStack(path: [.home])))
            try await generationRace(storage: storage) { store in
                RouterRestorationDriver(store: store, codec: codec, storage: storage)
            }
        } else {
            let codec = try codec()
            try storage.save(codec.encode(.rootStack(path: [.init(value: 1)])))
            try await generationRace(storage: storage) { store in
                RouterRestorationDriver(store: store, graphCodec: codec, storage: storage)
            }
        }
    }

    private func generationRace<T: Route>(
        storage: RouterFileSnapshotStorage,
        driver makeDriver: (RouterStore<T>) -> RouterRestorationDriver<T>
    ) async throws {
        let gate = WorkerGate()
        let session = Session()
        var configuration = RouterStoreConfiguration<T>(authorization: .init(
            generation: { session.generation }, requiresAuthorization: { _ in false },
            authorize: { true }
        ))
        configuration.runtimeDependencies.beforeRestorationWorker = { await gate.suspend() }
        let store = try RouterStore<T>(initialState: .rootStack, configuration: configuration)
        let original = try storage.load()
        let driver = makeDriver(store)
        let task = Task { @MainActor in try await driver.activate() }
        await gate.waitUntilEntered()
        session.generation += 1
        gate.open()
        guard case .restored(let outcome) = try await task.value,
              case .rejected(_, _, _, .authorization(let failure)) = outcome.transition else {
            Issue.record("An old activation must not adopt the new session generation")
            driver.stop()
            return
        }
        #expect(failure.code == .generationChanged)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(try storage.load() == original)
        driver.stop()
    }

    @Test("A stopped or superseded graph activation never applies old loaded bytes", arguments: [false, true])
    func staleAndStop(stopped: Bool) async throws {
        let (directory, storage) = try file()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = try codec()
        let original = try codec.encode(.rootStack(path: [.init(value: 1)]))
        try storage.save(original)
        let gate = WorkerGate()
        var configuration = RouterStoreConfiguration<R>()
        configuration.runtimeDependencies.beforeRestorationWorker = { await gate.suspend() }
        let store = try RouterStore<R>(initialState: .rootStack, configuration: configuration)
        let driver = RouterRestorationDriver(store: store, graphCodec: codec, storage: storage)
        let task = Task { @MainActor in try await driver.activate() }
        await gate.waitUntilEntered()
        if stopped { driver.stop() }
        else { _ = await store.perform(.push(.init(value: 7))) }
        gate.open()
        if stopped { await #expect(throws: CancellationError.self) { try await task.value } }
        else {
            guard case .restored(let result) = try await task.value, case .rejected = result.transition else {
                Issue.record("Concurrent navigation must reject the old graph candidate")
                return
            }
        }
        #expect(store.state == (stopped ? .rootStack : .rootStack(path: [.init(value: 7)])))
        #expect(store.revision == (stopped ? 0 : 1))
        #expect(try storage.load() == original)
        driver.stop()
    }

    @Test("Explicit legacy app migration is stored as graph only after an admitted save", arguments: [false, true])
    func explicitLegacyMigration(reject: Bool) async throws {
        let (directory, storage) = try file()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try RouterSnapshotCodec<Legacy>(currentVersion: 17)
        let original = try legacy.encode(.rootStack(path: [.home]))
        try storage.save(original)
        let adapter = RouterLegacySnapshotAdapter<R>(codec: legacy) { _ in
            .rootStack(path: [.init(value: 9)])
        }
        let graph = try codec(legacyAdapter: adapter)
        let configuration = RouterStoreConfiguration<R>(policies: reject ? [
            .init(name: "migration-control") { _ in .reject("migration not accepted") }
        ] : [])
        let store = try RouterStore<R>(initialState: .rootStack, configuration: configuration)
        let driver = RouterRestorationDriver(store: store, graphCodec: graph, storage: storage)
        guard case .restored(let result) = try await driver.activate() else {
            Issue.record("Expected explicit legacy migration result")
            return
        }
        #expect(try storage.load() == original)
        if reject {
            guard case .rejected = result.transition else { Issue.record("Policy must remain authoritative"); return }
            #expect(store.state == .rootStack)
            #expect(store.revision == 0)
        } else {
            guard case .applied = result.transition else { Issue.record("Expected accepted migration"); return }
            #expect(store.state == .rootStack(path: [.init(value: 9)]))
            try await driver.save()
            let encoded = try #require(try storage.load())
            #expect(encoded != original)
            #expect(try graph.decode(encoded) == store.state)
            let envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: encoded)
            #expect(envelope.schemaID == "test.graph")
            #expect(envelope.schemaVersion == 3)
        }
        driver.stop()
    }

    @Test("Graph restore uses the existing bounded partial validator")
    func partialGraphRestore() async throws {
        let (directory, storage) = try file()
        defer { try? FileManager.default.removeItem(at: directory) }
        let graph = try codec()
        try storage.save(graph.encode(.rootStack(path: [.init(value: 1), .init(value: 2)])))
        let store = try RouterStore<R>(initialState: .rootStack)
        let driver = RouterRestorationDriver(
            store: store, graphCodec: graph, storage: storage,
            validator: .init { route, _ in route.value == 2 ? .remove(reason: "retired") : .keep }
        )
        guard case .restored(let result) = try await driver.activate(), case .applied = result.transition else {
            Issue.record("The canonical partial planner must apply its accepted graph result")
            return
        }
        #expect(store.state == .rootStack(path: [.init(value: 1)]))
        #expect(driver.lastPartialRestoration != nil)
        #expect(store.restorationOperations.activeCount == 0)
        driver.stop()
    }

    @MainActor private final class Session { var generation: UInt64 = 0 }

    @MainActor private final class WorkerGate {
        private var entered = false
        private var opened = false
        private var entry: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func suspend() async {
            entered = true
            entry?.resume()
            entry = nil
            guard !opened else { return }
            await withCheckedContinuation { release = $0 }
        }
        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entry = $0 }
        }
        func open() {
            opened = true
            release?.resume()
            release = nil
        }
    }
}
