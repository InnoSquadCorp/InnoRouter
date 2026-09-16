import Foundation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

#if canImport(AppKit)
import AppKit
import SwiftUI

private enum PublicationCleanupRoute: String, Route, Codable { case current }
enum PublicationWaitFault: CaseIterable, Sendable {
    case finishedStream, missingEvent, cancelledCaller, stoppedWorker
}

private struct PublicationCleanupStorage: RouterSnapshotStorage {
    func load() -> Data? { nil }
    func save(_: Data) {}
    func remove() {}
}

@Suite("Publication failure cleanup", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterPublicationCleanupTests {
    @Test("Each failed wait releases the mounted host, stream, worker and queue", arguments: PublicationWaitFault.allCases)
    func injectedFailureCleanup(fault: PublicationWaitFault) async throws {
        // Repeat with a fresh fixture so one successful cleanup cannot hide a
        // poisoned global UI/test executor or an orphaned worker.
        for _ in 0 ..< 2 { try await probe(fault) }
    }

    private func probe(_ fault: PublicationWaitFault) async throws {
        let gate = ManualRuntimeSleeper()
        let starts = Mutex(0)
        let finishes = Mutex(0)
        var configuration = RouterStoreConfiguration<PublicationCleanupRoute>()
        configuration.runtimeDependencies.beforeRestorationWorker = {
            let first = starts.withLock { count in count += 1; return count == 1 }
            if first { try await gate.sleep(for: .seconds(60)) }
        }
        configuration.runtimeDependencies.didFinishRestorationWorker = {
            finishes.withLock { $0 += 1 }
        }
        let store = RouterStore(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: PublicationCleanupStorage()
        )
        let host = NSHostingView(rootView: AnyView(Color.clear.routerStateRestoration(driver)))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let (events, continuation) = AsyncStream<String>.makeStream()
        let terminations = Mutex(0)
        continuation.onTermination = { _ in terminations.withLock { $0 += 1 } }
        var reader: Task<[String], any Error>?
        defer {
            reader?.cancel()
            continuation.finish()
            driver.stop()
            window.contentView = nil
            window.orderOut(nil)
            Task { await gate.resumeAll() }
        }

        _ = try await firstElement(from: gate.registrations, what: "mounted worker suspended")
        #expect(driver.attachmentCount == 1)
        #expect(driver.activationWaiterCount == 1)
        #expect(store.eventObservationCount == 1)
        let waiting = Task { try await waitForEvent("required", from: events, timeout: .milliseconds(25)) }
        reader = waiting
        switch fault {
        case .finishedStream: continuation.finish()
        case .missingEvent: continuation.yield("unrelated")
        case .cancelledCaller: waiting.cancel()
        case .stoppedWorker:
            driver.stop()
            continuation.finish()
        }

        var failures = 0
        do {
            _ = try await waiting.value
            Issue.record("Injected failure unexpectedly succeeded")
        } catch {
            failures += 1
            switch (fault, error) {
            case (.cancelledCaller, is CancellationError): break
            case (.missingEvent, RouterTestWaitFailure.timedOut): break
            case (.finishedStream, RouterTestWaitFailure.streamFinished),
                 (.stoppedWorker, RouterTestWaitFailure.streamFinished): break
            default: Issue.record("Unexpected failure category: \(error)")
            }
        }
        #expect(failures == 1)
        continuation.finish()
        #expect(terminations.withLock { $0 } == 1)

        // Assert natural host removal before the emergency defer calls stop.
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        try await waitUntil("all mounted ownership released") {
            driver.attachmentCount == 0 && store.eventObservationCount == 0
                && driver.activationWaiterCount == 0 && finishes.withLock { $0 } == 1
        }
        #expect(await gate.pendingCount == 0)
        window.contentView = nil
        #expect(window.contentView == nil)

        // Cleanup must leave the same driver and production queue usable.
        _ = try await driver.activate()
        guard case .applied = await store.perform(.push(.current)) else {
            Issue.record("Cleanup poisoned the next navigation request")
            return
        }
        #expect(store.revision == 1)
        #expect(driver.activationWaiterCount == 0)
        driver.stop()
        #expect(store.eventObservationCount == 0)
    }
}
#endif
