import Foundation
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

private enum FifteenthReviewRoute: String, Route, Codable {
    case first
    case second
    case followup
}

private enum FifteenthReviewSceneRoute: Route, RouterSceneRoute {
    case window
    case immersive

    static let routerScenes: [RouterSceneDescriptor<Self>] = [
        .init(route: .window, id: "review-window", style: .window),
        .init(route: .immersive, id: "review-immersive", style: .immersiveSpace),
    ]
}

@MainActor
private final class FifteenthReviewSceneGate {
    let events: AsyncStream<String>
    private let eventContinuation: AsyncStream<String>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    var recorded: [String] = []

    init() {
        let pair = AsyncStream.makeStream(of: String.self)
        events = pair.stream
        eventContinuation = pair.continuation
    }

    func record(_ event: String) {
        recorded.append(event)
        eventContinuation.yield(event)
    }

    func block() async -> Bool {
        record("blocked")
        await withCheckedContinuation { releaseContinuation = $0 }
        return true
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    /// Releases the gate and ends the event stream so every pending wait
    /// finishes instead of hanging when a test exits before the last event.
    func finish() {
        release()
        eventContinuation.finish()
    }
}

@MainActor
private final class FifteenthReviewHistoryCommitHook {
    weak var store: RouterStore<FifteenthReviewRoute>?
    var followup: Task<Void, Never>?
    var isArmed = false

    func observe(_ event: RouterEvent<FifteenthReviewRoute>) {
        guard isArmed,
              case .committed(_, _, _, _, let context) = event,
              context.source == .history,
              let store else { return }
        isArmed = false
        followup = Task { @MainActor in
            _ = await store.perform(.push(.followup))
        }
    }
}

@Suite("Fifteenth review regressions", .timeLimit(.minutes(1)))
@MainActor
struct RouterFifteenthReviewRegressionTests {
    @Test("A checkpoint completion cannot overwrite a newer history commit")
    func checkpointCompletionPreservesFollowupCommit() async throws {
        let hook = FifteenthReviewHistoryCommitHook()
        let store = RouterStore<FifteenthReviewRoute>(configuration: .init(
            onEvent: { hook.observe($0) }
        ))
        hook.store = store
        let history = RouterHistory(store: store)
        _ = history.createCheckpoint(named: "empty")
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))

        hook.isArmed = true
        let result = await history.restoreCheckpoint(named: "empty")
        await hook.followup?.value

        guard case .completed = result else {
            Issue.record("Expected checkpoint restoration to complete")
            history.stop()
            return
        }
        #expect(store.state.root == .stack(path: [.followup]))
        #expect(history.currentEntry.navigationState.root == store.state.root)
        #expect(history.canGoBack)
        _ = await history.goBack()
        #expect(store.state.root == .stack(path: []))
        history.stop()
    }

    @Test("Checkpoint entry creation resumes record waiters")
    func checkpointEntryResumesRecordWaiter() async throws {
        let sourceStore = RouterStore<FifteenthReviewRoute>()
        let sourceHistory = RouterHistory(store: sourceStore)
        _ = await sourceStore.perform(.push(.first))
        let checkpoint = try sourceHistory.createCheckpoint(named: "imported").get()

        let store = RouterStore<FifteenthReviewRoute>()
        let history = RouterHistory(store: store)
        _ = try history.importCheckpoint(checkpoint).get()
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registration = registrations.makeAsyncIterator()
        let waiter = Task {
            await history.waitUntilRecorded(2) {
                registrationContinuation.yield()
            }
        }
        defer {
            waiter.cancel()
            registrationContinuation.finish()
            history.stop()
            sourceHistory.stop()
        }
        #expect(await registration.next() != nil)
        #expect(history.entries.count == 1)

        let result = await history.restoreCheckpoint(named: "imported")

        guard case .completed = result else {
            Issue.record("Expected imported checkpoint restoration to complete")
            return
        }
        #expect(await waiter.value)
        #expect(history.entries.count == 2)
        #expect(history.currentEntry.navigationState.root == .stack(path: [.first]))
    }

#if canImport(AppKit)
    @Test("Removing a scene driver cancels its queued immersive effect")
    func removedSceneDriverSkipsQueuedEffect() async throws {
        let gate = FifteenthReviewSceneGate()
        let blocker = Task {
            await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue {
                await gate.block()
            }
        }
        defer {
            gate.finish()
            blocker.cancel()
        }
        try await waitForEvent("blocked", from: gate.events)

        let store = RouterStore(initialState: try RouterState<FifteenthReviewSceneRoute>(
            windows: [.init(route: .window)],
            immersiveSpace: .init(id: "review-immersive", route: .immersive)
        ))
        let host = NSHostingView(rootView: AnyView(
            RouterSceneDriver(store: store, onEvent: { event in
                switch event {
                case .openedWindow:
                    gate.record("window-opened")
                case .unsupported:
                    gate.record("unsupported-effect")
                default:
                    break
                }
            }) { Color.clear }
                .onDisappear { gate.record("driver-disappeared") }
        ))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await waitForEvent("window-opened", from: gate.events)

        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        try await waitForEvent("driver-disappeared", from: gate.events)
        gate.release()
        #expect(await blocker.value)
        #expect(await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue { true })

        #expect(gate.recorded == ["blocked", "window-opened", "driver-disappeared"])
        #expect(store.state.immersiveSpace?.id == "review-immersive")
    }
#endif
}
