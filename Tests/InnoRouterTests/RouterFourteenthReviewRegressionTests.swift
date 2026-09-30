import Foundation
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

private enum FourteenthReviewRoute: String, Route, Codable {
    case first
    case second
}

private struct FourteenthReviewStorage: RouterSnapshotStorage {
    let data: Data

    func load() throws -> Data? { data }
    func save(_ data: Data) throws {}
    func remove() throws {}
}

@MainActor
private final class FourteenthReviewCancellation {
    var cancel: () -> Void = {}
}

@MainActor
private final class FourteenthReviewImmersiveOpenGate {
    var isNativeOpen = false
    var events: [String] = []
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func open() async -> RouterImmersiveSpaceOpenResult {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
        }
        isNativeOpen = true
        events.append("obsolete-open")
        return .opened
    }

    func dismiss() {
        isNativeOpen = false
        events.append("obsolete-dismiss")
    }

    func markOpen(_ event: String = "open") {
        isNativeOpen = true
        events.append(event)
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum FourteenthReviewSceneRoute: Route, RouterSceneRoute {
    case supported
    case unsupported

    static let routerScenes: [RouterSceneDescriptor<Self>] = [
        .init(route: .supported, id: "supported", style: .window),
        .init(route: .unsupported, id: "unsupported", style: .window),
    ]
}

@MainActor
private final class FourteenthReviewSceneTrace {
    var events: [RouterSceneDriverEvent<FourteenthReviewSceneRoute>] = []
    let stream: AsyncStream<RouterSceneDriverEvent<FourteenthReviewSceneRoute>>
    private let continuation: AsyncStream<RouterSceneDriverEvent<FourteenthReviewSceneRoute>>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: RouterSceneDriverEvent<FourteenthReviewSceneRoute>.self
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func record(_ event: RouterSceneDriverEvent<FourteenthReviewSceneRoute>) {
        events.append(event)
        continuation.yield(event)
    }
}

@Suite("Fourteenth review regressions")
@MainActor
struct RouterFourteenthReviewRegressionTests {
    @Test("Cancelling restoration after deferral releases its request family")
    func activationCancellationAtDeferralReleasesCapacity() async throws {
        let cancellation = FourteenthReviewCancellation()
        let deferralID = RouterDeferralID()
        let codec = try RouterSnapshotCodec<FourteenthReviewRoute>(currentVersion: 1)
        let saved = try codec.encode(RouterState(root: .stack(path: [.first])))
        let store = RouterStore<FourteenthReviewRoute>(configuration: .init(
            policies: [RouterPolicy(name: "defer") { transition in
                .deferRequest(
                    transition.context.source == .restoration
                        ? deferralID
                        : RouterDeferralID()
                )
            }],
            deferrals: .init(maximumPendingCount: 1),
            onEvent: { event in
                if case .deferred = event {
                    cancellation.cancel()
                }
            }
        ))
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: FourteenthReviewStorage(data: saved)
        )
        let activation = Task { try await driver.activate() }
        cancellation.cancel = { activation.cancel() }

        do {
            _ = try await activation.value
            Issue.record("Expected caller cancellation")
        } catch is CancellationError {}

        #expect(driver.status == .inactive)
        #expect(store.deferredTransitions.isEmpty)

        cancellation.cancel = {}
        let next = await store.perform(.push(.second))
        if case .rejected(_, _, _, .deferralCapacityExceeded) = next {
            Issue.record("Cancelled restoration retained the only deferral slot")
        }
        for deferred in store.deferredTransitions {
            _ = await store.cancelDeferred(deferred.id)
        }
        driver.stop()
    }

    @Test("History instances synchronize history-originated navigation")
    func secondHistoryTracksFirstHistoryNavigation() async {
        let store = RouterStore<FourteenthReviewRoute>()
        let first = RouterHistory(store: store)
        let second = RouterHistory(store: store)
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))

        _ = await first.goBack()

        #expect(second.currentEntry.navigationState.root == store.state.root)
        #expect(second.cursor == 1)
        let outcome = await second.goBack()
        if case .completed(_, .unchanged) = outcome {
            Issue.record("Second history moved its cursor without moving canonical state")
        }
        #expect(store.state.root == .stack(path: []))
        first.stop()
        second.stop()
    }

    @Test("An unseen external history destination becomes a local history entry")
    func externalHistoryDestinationRecordsWhenNoEntryMatches() async {
        let store = RouterStore<FourteenthReviewRoute>()
        let first = RouterHistory(store: store)
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))
        let late = RouterHistory(store: store)

        _ = await first.goBack()

        #expect(late.entries.count == 2)
        #expect(late.cursor == 1)
        #expect(late.currentEntry.navigationState.root == .stack(path: [.first]))
        _ = await late.goBack()
        #expect(store.state.root == .stack(path: [.first, .second]))
        first.stop()
        late.stop()
    }

    @Test("An obsolete immersive reopen is compensated before the queue advances")
    func obsoleteImmersiveRestoreClosesSuccessfulNativeOpen() async throws {
        let store = RouterStore(initialState: try RouterState<FourteenthReviewRoute>(
            immersiveSpace: .init(id: "theater", route: .first)
        ))
        let lifetime = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(
            store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(
                id: "theater",
                lifecycleToken: lifetime
            )
        )
        let gate = FourteenthReviewImmersiveOpenGate()
        let restoration = Task {
            await restoreRouterImmersiveSpaceAfterDeferredClosure(
                id: "theater",
                lifecycleToken: lifetime,
                ticket: ticket,
                store: store,
                open: { await gate.open() },
                dismiss: { gate.dismiss() }
            )
        }

        await gate.waitUntilEntered()
        _ = await store.perform(.dismissImmersiveSpace)
        gate.release()

        #expect(await restoration.value == false)
        #expect(store.state.immersiveSpace == nil)
        #expect(!gate.isNativeOpen)
    }

    @Test("Immersive effect serialization cleans an obsolete open before replacement")
    func obsoleteImmersiveCleanupPrecedesReplacementOpen() async throws {
        let store = RouterStore(initialState: try RouterState<FourteenthReviewRoute>(
            immersiveSpace: .init(id: "theater", route: .first)
        ))
        let lifetime = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(
            store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(
                id: "theater",
                lifecycleToken: lifetime
            )
        )
        let gate = FourteenthReviewImmersiveOpenGate()
        let obsolete = Task {
            await restoreRouterImmersiveSpaceAfterDeferredClosure(
                id: "theater",
                lifecycleToken: lifetime,
                ticket: ticket,
                store: store,
                open: { await gate.open() },
                dismiss: { gate.dismiss() }
            )
        }

        await gate.waitUntilEntered()
        _ = await store.perform(.dismissImmersiveSpace)
        _ = await store.perform(
            .enterImmersiveSpace(.init(id: "theater", route: .second))
        )
        let replacement = Task {
            await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue {
                gate.markOpen("replacement-open")
                return true
            }
        }
        gate.release()

        #expect(await obsolete.value == false)
        #expect(await replacement.value)
        #expect(gate.isNativeOpen)
        #expect(gate.events == [
            "obsolete-open",
            "obsolete-dismiss",
            "replacement-open",
        ])
        #expect(store.state.immersiveSpace?.route == .second)
    }

    @Test("Caller cancellation cannot abandon a running immersive effect queue")
    func immersiveEffectQueueFinishesRunningWorkBeforeAdvancing() async {
        let queue = RouterImmersiveSceneEffectQueue()
        let gate = FourteenthReviewImmersiveOpenGate()
        let first = Task {
            await queue.enqueue {
                _ = await gate.open()
                return true
            }
        }
        await gate.waitUntilEntered()
        first.cancel()
        let second = Task {
            await queue.enqueue {
                gate.markOpen("next-effect")
                return true
            }
        }
        gate.release()

        #expect(await first.value)
        #expect(await second.value)
        #expect(gate.events == ["obsolete-open", "next-effect"])
    }

    @Test("A matching immersive appearance consumes its ticket without closing the space")
    func matchingImmersiveAppearanceKeepsSuccessfulNativeOpen() async throws {
        let store = RouterStore(initialState: try RouterState<FourteenthReviewRoute>(
            immersiveSpace: .init(id: "theater", route: .first)
        ))
        let lifetime = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(
            store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(
                id: "theater",
                lifecycleToken: lifetime
            )
        )
        let gate = FourteenthReviewImmersiveOpenGate()

        let keepsReservation = await restoreRouterImmersiveSpaceAfterDeferredClosure(
            id: "theater",
            lifecycleToken: lifetime,
            ticket: ticket,
            store: store,
            open: {
                gate.markOpen()
                store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
                    id: "theater",
                    lifecycleToken: lifetime,
                    ticket: ticket
                )
                return .opened
            },
            dismiss: { gate.dismiss() }
        )

        #expect(keepsReservation)
        #expect(gate.isNativeOpen)
        #expect(store.state.immersiveSpace?.id == "theater")
    }

#if canImport(AppKit)
    @Test("A partial scene reconciliation preserves an already-opened window")
    func incompleteReconciliationDoesNotReopenUnaffectedWindow() async throws {
        let first = RouterWindow(id: UUID(), route: FourteenthReviewSceneRoute.supported)
        let second = RouterWindow(id: UUID(), route: FourteenthReviewSceneRoute.unsupported)
        let store = RouterStore(initialState: try RouterState(windows: [first, second]))
        let catalog = try RouterSceneCatalog<FourteenthReviewSceneRoute>([
            .init(route: .supported, id: "supported", style: .window),
        ])
        let trace = FourteenthReviewSceneTrace()
        var storeEvents = store.events.makeAsyncIterator()
        var sceneEvents = trace.stream.makeAsyncIterator()
        let host = NSHostingView(rootView: RouterSceneDriver(
            store: store,
            catalog: catalog,
            onEvent: { trace.record($0) }
        ) { Color.clear })
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        while let event = await storeEvents.next() {
            guard case .committed(_, _, let after, _, let context) = event,
                  context.source == .system,
                  after.windows == [first] else {
                continue
            }
            break
        }

        let completionSentinel = RouterWindow(
            id: UUID(),
            route: FourteenthReviewSceneRoute.supported
        )
        _ = await store.perform(.openWindow(completionSentinel))
        while let event = await sceneEvents.next() {
            guard case .openedWindow(let opened, _) = event,
                  opened.id == completionSentinel.id else {
                continue
            }
            break
        }

        #expect(store.state.windows == [first, completionSentinel])
        let opens = trace.events.filter {
            if case .openedWindow(let window, _) = $0 {
                return window.id == first.id
            }
            return false
        }
        let dismissals = trace.events.filter {
            if case .dismissedWindow(let window, _) = $0 {
                return window.id == first.id
            }
            return false
        }
        #expect(opens.count == 1)
        #expect(dismissals.isEmpty)
        window.contentView = nil
    }
#endif
}
