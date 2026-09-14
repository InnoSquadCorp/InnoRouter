import Foundation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

private enum SixteenthReviewRoute: String, Route, Codable {
    case first
    case second
    case blocker
}

@MainActor
private final class SixteenthReviewHistoryGate {
    let events: AsyncStream<String>
    let continuation: AsyncStream<String>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func block() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            self.continuation.yield("blocked")
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class SixteenthReviewHistoryHook {
    enum Resolution {
        case resume
        case cancel
    }

    weak var store: RouterStore<SixteenthReviewRoute>?
    var resolution: Resolution = .resume
    private(set) var followups: [Task<Void, Never>] = []

    func observe(_ event: RouterEvent<SixteenthReviewRoute>) {
        guard let store,
              case .deferred(_, _, _, let deferral, let context) = event,
              context.source == .history else {
            return
        }
        let resolution = resolution
        followups.append(Task { @MainActor in
            switch resolution {
            case .resume:
                _ = await store.resumeDeferred(deferral.id)
            case .cancel:
                _ = await store.cancelDeferred(deferral.id)
            }
        })
    }

    func waitForFollowups() async {
        for followup in followups {
            await followup.value
        }
    }
}

private final class SixteenthReviewBlockingStorage: RouterSnapshotStorage {
    private enum StorageError: Error {
        case loadTimedOut
    }

    let loads: AsyncStream<Void>
    let saves: AsyncStream<Data>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let saveContinuation: AsyncStream<Data>.Continuation
    private let releaseLoad = DispatchSemaphore(value: 0)
    private let loadCount = Mutex(0)
    private let savedCount = Mutex(0)

    init() {
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
        (saves, saveContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    deinit {
        releaseLoad.signal()
        loadContinuation.finish()
        saveContinuation.finish()
    }

    var saveCount: Int { savedCount.withLock { $0 } }

    func release() {
        releaseLoad.signal()
    }

    func load() throws -> Data? {
        let count = loadCount.withLock {
            $0 += 1
            return $0
        }
        if count == 1 {
            loadContinuation.yield()
            guard releaseLoad.wait(timeout: .now() + 5) == .success else {
                throw StorageError.loadTimedOut
            }
        }
        return nil
    }

    func save(_ data: Data) throws {
        savedCount.withLock { $0 += 1 }
        saveContinuation.yield(data)
    }

    func remove() throws {}
}

#if canImport(AppKit)
@MainActor
private struct SixteenthReviewRestorationRoot: View {
    let driver: RouterRestorationDriver<SixteenthReviewRoute>

    var body: some View {
        Color.clear.routerStateRestoration(driver)
    }
}
#endif

@Suite("Sixteenth review regressions", .timeLimit(.minutes(1)))
@MainActor
struct RouterSixteenthReviewRegressionTests {
    @Test("Queued deferred history resume consumes ownership at the event boundary")
    func queuedHistoryImmediateResume() async {
        await verifyQueuedHistoryResolution(.resume)
    }

    @Test("Queued deferred history cancellation consumes ownership at the event boundary")
    func queuedHistoryImmediateCancellation() async {
        await verifyQueuedHistoryResolution(.cancel)
    }

    @Test("Cancelling one restoration attachment preserves another attachment and its saves")
    func sharedRestorationAttachmentSurvivesCallerCancellation() async throws {
        let storage = SixteenthReviewBlockingStorage()
        defer { storage.release() }
        var loads = storage.loads.makeAsyncIterator()
        var saves = storage.saves.makeAsyncIterator()
        let codec = try RouterSnapshotCodec<SixteenthReviewRoute>(currentVersion: 1)
        let store = RouterStore<SixteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = Task { @MainActor in try await driver.attach(firstID) }
        #expect(await loads.next() != nil)

        #expect(try await driver.attach(secondID) == .alreadyActive)
        first.cancel()
        driver.detach(firstID)
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(store.eventObservationCount == 1)

        _ = await store.perform(.push(.first))
        storage.release()
        let saved = try #require(await saves.next())
        #expect(try codec.decode(saved).root == .stack(path: [.first]))
        #expect(storage.saveCount == 1)
        #expect(store.eventObservationCount == 1)

        driver.detach(secondID)
        #expect(store.eventObservationCount == 0)
        #expect(driver.status == .inactive)
    }

    @Test("A manual activation cancellation cannot stop a live attached owner")
    func attachedOwnerSurvivesManualActivationCancellation() async throws {
        let storage = SixteenthReviewBlockingStorage()
        defer { storage.release() }
        var loads = storage.loads.makeAsyncIterator()
        var saves = storage.saves.makeAsyncIterator()
        let codec = try RouterSnapshotCodec<SixteenthReviewRoute>(currentVersion: 1)
        let store = RouterStore<SixteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let manual = Task { @MainActor in try await driver.activate() }
        #expect(await loads.next() != nil)
        let attachmentID = UUID()
        #expect(try await driver.attach(attachmentID) == .alreadyActive)

        manual.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await manual.value
        }
        #expect(store.eventObservationCount == 1)

        _ = await store.perform(.push(.second))
        storage.release()
        let saved = try #require(await saves.next())
        #expect(try codec.decode(saved).root == .stack(path: [.second]))
        driver.detach(attachmentID)
        #expect(store.eventObservationCount == 0)
    }

    @Test("Detaching a temporary host cannot cancel an in-flight manual activation")
    func manualActivationOwnsWorkAfterAttachmentDetaches() async throws {
        let storage = SixteenthReviewBlockingStorage()
        defer { storage.release() }
        var loads = storage.loads.makeAsyncIterator()
        let codec = try RouterSnapshotCodec<SixteenthReviewRoute>(currentVersion: 1)
        let store = RouterStore<SixteenthReviewRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let manual = Task { @MainActor in try await driver.activate() }
        #expect(await loads.next() != nil)

        let attachmentID = UUID()
        #expect(try await driver.attach(attachmentID) == .alreadyActive)
        driver.detach(attachmentID)
        #expect(store.eventObservationCount == 1)

        manual.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await manual.value
        }
        #expect(store.eventObservationCount == 0)
        storage.release()
        #expect(try await driver.activate() == .noSnapshot)
        driver.stop()
    }

#if canImport(AppKit)
    @Test("Removing the first of two mounted restoration roots preserves the second root")
    func mountedRestorationRootsShareActivationLifetime() async throws {
        let storage = SixteenthReviewBlockingStorage()
        defer { storage.release() }
        var loads = storage.loads.makeAsyncIterator()
        var saves = storage.saves.makeAsyncIterator()
        let codec = try RouterSnapshotCodec<SixteenthReviewRoute>(currentVersion: 1)
        let store = RouterStore<SixteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let firstHost = NSHostingView(rootView: AnyView(
            SixteenthReviewRestorationRoot(driver: driver)
        ))
        let secondHost = NSHostingView(rootView: AnyView(
            SixteenthReviewRestorationRoot(driver: driver)
        ))
        let firstWindow = makeWindow(firstHost)
        let secondWindow = makeWindow(secondHost)
        await render(firstHost)
        #expect(await loads.next() != nil)
        await render(secondHost)
        #expect(driver.attachmentCount == 2)

        firstHost.rootView = AnyView(Color.clear)
        await render(firstHost)
        #expect(driver.attachmentCount == 1)
        #expect(store.eventObservationCount == 1)

        _ = await store.perform(.push(.first))
        storage.release()
        let saved = try #require(await saves.next())
        #expect(try codec.decode(saved).root == .stack(path: [.first]))
        #expect(store.eventObservationCount == 1)

        secondHost.rootView = AnyView(Color.clear)
        await render(secondHost)
        #expect(driver.attachmentCount == 0)
        #expect(store.eventObservationCount == 0)
        #expect(driver.status == .inactive)

        firstWindow.contentView = nil
        secondWindow.contentView = nil
        driver.stop()
    }
#endif

    private func verifyQueuedHistoryResolution(
        _ resolution: SixteenthReviewHistoryHook.Resolution
    ) async {
        let gate = SixteenthReviewHistoryGate()
        var events = gate.events.makeAsyncIterator()
        let hook = SixteenthReviewHistoryHook()
        hook.resolution = resolution
        var configuration = RouterStoreConfiguration<SixteenthReviewRoute>(
            policies: [RouterPolicy(name: "sixteenth-review") { transition in
                if transition.action == .push(.blocker) {
                    await gate.block()
                    return .reject("released")
                }
                if transition.context.source == .history {
                    return .deferRequest(.init())
                }
                return .allow
            }],
            onEvent: { hook.observe($0) }
        )
        configuration.runtimeDependencies.didQueueRequest = { _ in
            gate.continuation.yield("queued")
        }
        let store = RouterStore<SixteenthReviewRoute>(configuration: configuration)
        hook.store = store
        let history = RouterHistory(store: store)
        _ = history.createCheckpoint(named: "empty")
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))

        let blocker = Task { @MainActor in await store.perform(.push(.blocker)) }
        #expect(await events.next() == "blocked")
        let movement = Task { @MainActor in
            await history.restoreCheckpoint(named: "empty")
        }
        #expect(await events.next() == "queued")
        gate.release()
        guard case .rejected = await blocker.value else {
            Issue.record("Expected the queue blocker to reject")
            history.stop()
            return
        }
        guard case .deferred = await movement.value else {
            Issue.record("Expected the original history request to report its deferred outcome")
            history.stop()
            return
        }
        await hook.waitForFollowups()

        #expect(store.deferredTransitions.isEmpty)
        #expect(history.pendingMoves.isEmpty)
        #expect(history.ownedRequestRoots.isEmpty)
        #expect(history.activeRequestMoves.isEmpty)
        switch resolution {
        case .resume:
            #expect(store.revision == 3)
            #expect(history.cursor == 0)
            #expect(history.currentEntry.sourceRevision == store.revision)
            #expect(history.currentEntry.navigationState.root == .stack(path: []))
        case .cancel:
            #expect(store.revision == 2)
            #expect(history.cursor == 2)
            #expect(history.currentEntry.sourceRevision == store.revision)
            #expect(history.currentEntry.navigationState.root == .stack(path: [.first, .second]))
        }
        history.stop()
    }

#if canImport(AppKit)
    private func makeWindow(_ host: NSHostingView<AnyView>) -> NSWindow {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    private func render(_ host: NSHostingView<AnyView>) async {
        host.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        host.layoutSubtreeIfNeeded()
    }
#endif
}
