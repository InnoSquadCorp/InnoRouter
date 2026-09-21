import Foundation
import SwiftUI
import InnoRouter

@Router
enum RestorationProbeRoute: Codable {
    case detail
    var destination: some View { Text("Restored detail") }
}

private struct ProbeStorage: RouterSnapshotStorage {
    let file: RouterFileSnapshotStorage
    let directory: URL
    func load() throws -> Data? { try file.load() }
    func save(_ data: Data) throws {
        try file.save(data)
        try Data("SAVED".utf8).write(to: directory.appending(path: "saved.txt"), options: .atomic)
    }
    func remove() throws { try file.remove() }
}

@MainActor
@Observable
private final class ProbeSession {
    let store = RouterStore<RestorationProbeRoute>()
    let driver: RouterRestorationDriver<RestorationProbeRoute>
    let directory: URL
    var result = "Starting"

    init() throws {
        directory = URL.applicationSupportDirectory.appending(path: "RestorationProbe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.arguments.contains("--seed") {
            for name in ["snapshot.json", "ready.txt", "saved.txt", "result.txt"] {
                let url = directory.appending(path: name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        driver = RouterRestorationDriver(
            store: store,
            codec: try RouterSnapshotCodec(currentVersion: 1),
            storage: ProbeStorage(file: .init(fileURL: directory.appending(path: "snapshot.json")), directory: directory),
            saveDebounce: .seconds(3_600)
        )
    }

    func run() async {
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while driver.lastActivation == nil {
                if case .failed(let reason) = driver.status { throw ProbeError(reason: reason) }
                guard ContinuousClock.now < deadline else { throw ProbeError(reason: "Restore timeout") }
                try await Task.sleep(for: .milliseconds(10))
            }
            if ProcessInfo.processInfo.arguments.contains("--seed") {
                guard case .applied = await store.perform(.push(.detail)) else {
                    throw ProbeError(reason: "Navigation was not applied")
                }
                result = "READY_FOR_BACKGROUND"
                try Data(result.utf8).write(to: directory.appending(path: "ready.txt"), options: .atomic)
            } else {
                guard store.state.root == .stack(path: [.detail]) else {
                    throw ProbeError(reason: "Saved detail was not restored")
                }
                result = "PASS restored detail after process restart"
                try Data(result.utf8).write(to: directory.appending(path: "result.txt"), options: .atomic)
            }
        } catch {
            result = "FAIL: \(error)"
            try? Data(result.utf8).write(to: directory.appending(path: "result.txt"), options: .atomic)
        }
    }
}

private struct ProbeError: Error { let reason: String }

@main
struct RouterRestorationProbeApp: App {
    @State private var session = try? ProbeSession()

    var body: some Scene {
        WindowGroup {
            if let session {
                RouterHost(store: session.store) { Text(session.result) }
                    .routerStateRestoration(session.driver)
                    .task { await session.run() }
            } else {
                Text("FAIL: Probe initialization")
            }
        }
    }
}
