// MARK: - RouterThirteenthReviewRegressionTests.swift
import Foundation
import SwiftUI
import Testing

#if canImport(AppKit)
import AppKit
#endif

import InnoRouter
@testable import InnoRouterSwiftUI

private enum ThirteenthReviewRoute: String, DestinationRoute, Codable, RouterSceneRoute {
    case first
    case second
    case third

    @MainActor
    static func destination(for route: Self) -> some View {
        Text(route.rawValue)
    }

    static let routerScenes: [RouterSceneDescriptor<Self>] = [
        .init(route: .first, id: "first", style: .window),
        .init(route: .second, id: "second", style: .window),
    ]
}

private struct ThirteenthReviewSnapshotStorage: RouterSnapshotStorage {
    let data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws {}
    func remove() throws {}
}

@MainActor
private final class ThirteenthReviewPolicyGate {
    private let entries: AsyncStream<Void>
    private let entryContinuation: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?

    init() {
        (entries, entryContinuation) = AsyncStream.makeStream()
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entryContinuation.yield(())
        }
    }

    func waitUntilEntered() async {
        var iterator = entries.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Thirteenth review regressions")
@MainActor
struct RouterThirteenthReviewRegressionTests {
    @Test("A deferred native close cannot dismiss a replacement window lifetime")
    func deferredWindowCloseTargetsOriginalLifetime() async throws {
        let id = UUID()
        let deferral = RouterDeferralID()
        let initial = try RouterState<ThirteenthReviewRoute>(
            windows: [.init(id: id, route: .first)]
        )
        let store = RouterStore(initialState: initial, configuration: .init(policies: [
            RouterPolicy(name: "native-close") { transition in
                transition.context.source == .system ? .deferRequest(deferral) : .allow
            },
        ]))
        let originalLifetime = try #require(store.windowLifecycleTokens[id])

        guard case .deferred = await synchronizeRouterWindowDisappearance(
            id: id,
            lifecycleToken: originalLifetime,
            store: store
        ) else {
            Issue.record("Expected the native close to defer")
            return
        }

        _ = await store.perform(.dismissWindow(id))
        _ = await store.perform(.openWindow(.init(id: id, route: .second)))
        #expect(store.windowLifecycleTokens[id] != originalLifetime)

        guard case .rejected(_, _, _, .cancelled) = await store.resumeDeferred(
            deferral,
            strategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the obsolete close lifetime to cancel")
            return
        }
        #expect(store.state.windows == [.init(id: id, route: .second)])
        #expect(store.revision == 2)
    }

    @Test("Stopping history cancels its active request family")
    func historyStopReleasesActivePolicyLane() async {
        let gate = ThirteenthReviewPolicyGate()
        let store = RouterStore<ThirteenthReviewRoute>(configuration: .init(
            policies: [RouterPolicy(name: "history") { transition in
                if transition.context.source == .history {
                    await gate.suspend()
                }
                return .allow
            }],
            schedulingPolicy: .rejectWhileBusy
        ))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))

        let move = Task { await history.goBack() }
        await gate.waitUntilEntered()
        history.stop()
        await Task.yield()

        let next = await store.perform(.push(.third))
        if case .rejected(_, _, _, .busy) = next {
            Issue.record("Stopped history left the router policy lane busy")
        }

        gate.release()
        _ = await move.value
    }

    @Test("Reset returns cancellation while releasing the previous history generation")
    func historyResetReleasesActivePolicyLane() async {
        let gate = ThirteenthReviewPolicyGate()
        let store = RouterStore<ThirteenthReviewRoute>(configuration: .init(
            policies: [RouterPolicy(name: "history") { transition in
                if transition.context.source == .history {
                    await gate.suspend()
                }
                return .allow
            }],
            schedulingPolicy: .rejectWhileBusy
        ))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))

        let move = Task { await history.goBack() }
        await gate.waitUntilEntered()
        history.reset(sessionKey: "replacement")
        guard case .unavailable(_, .cancelled) = await move.value else {
            Issue.record("Expected reset to cancel the prior history generation")
            gate.release()
            return
        }

        let next = await store.perform(.push(.third))
        if case .rejected(_, _, _, .busy) = next {
            Issue.record("Reset history left the router policy lane busy")
        }
        gate.release()
        history.stop()
    }

    @Test("Cancelling one history caller releases its request family")
    func historyCallerCancellationReleasesActivePolicyLane() async {
        let gate = ThirteenthReviewPolicyGate()
        let store = RouterStore<ThirteenthReviewRoute>(configuration: .init(
            policies: [RouterPolicy(name: "history") { transition in
                if transition.context.source == .history {
                    await gate.suspend()
                }
                return .allow
            }],
            schedulingPolicy: .rejectWhileBusy
        ))
        let history = RouterHistory(store: store)
        _ = await store.perform(.push(.first))
        _ = await store.perform(.push(.second))

        let move = Task { await history.goBack() }
        await gate.waitUntilEntered()
        move.cancel()
        guard case .unavailable(_, .cancelled) = await move.value else {
            Issue.record("Expected caller cancellation to end the history move")
            gate.release()
            return
        }

        let next = await store.perform(.push(.third))
        if case .rejected(_, _, _, .busy) = next {
            Issue.record("Cancelled history caller left the router policy lane busy")
        }
        gate.release()
        history.stop()
    }

    @Test("Stopping restoration removes the whole deferred restore family")
    func restorationStopReleasesDeferralCapacity() async throws {
        let codec = try RouterSnapshotCodec<ThirteenthReviewRoute>(currentVersion: 1)
        let restoreDeferral = RouterDeferralID()
        let nextDeferral = RouterDeferralID()
        let store = RouterStore<ThirteenthReviewRoute>(configuration: .init(
            policies: [RouterPolicy(name: "approval") { transition in
                .deferRequest(
                    transition.context.source == .restoration
                        ? restoreDeferral
                        : nextDeferral
                )
            }],
            deferrals: .init(maximumPendingCount: 1)
        ))
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: ThirteenthReviewSnapshotStorage(
                data: try codec.encode(.rootStack(path: [.first]))
            )
        )

        _ = try await driver.activate()
        #expect(store.deferredTransitions.map(\.id) == [restoreDeferral])
        driver.stop()

        guard case .deferred(_, _, _, let deferred) = await store.perform(.push(.second)) else {
            Issue.record("Expected released capacity to accept the next deferral")
            return
        }
        #expect(deferred.id == nextDeferral)
        _ = await store.cancelDeferred(nextDeferral)
    }

    @Test("Restoration leases keep shared drivers active until the last detach")
    func restorationAttachmentLeases() async throws {
        let codec = try RouterSnapshotCodec<ThirteenthReviewRoute>(currentVersion: 1)
        let driver = RouterRestorationDriver(
            store: RouterStore<ThirteenthReviewRoute>(),
            codec: codec,
            storage: ThirteenthReviewSnapshotStorage(data: nil)
        )
        let first = UUID()
        let second = UUID()

        _ = try await driver.attach(first)
        _ = try await driver.attach(second)
        driver.detach(first)
        #expect(driver.status == .active)

        driver.detach(second)
        #expect(driver.status == .inactive)

        _ = try await driver.activate()
        _ = try await driver.attach(first)
        driver.detach(first)
        #expect(driver.status == .active)
        driver.stop()
    }

    @Test("Stopping restoration cancels a repeatedly deferred request family")
    func restorationStopCancelsRepeatedDeferral() async throws {
        let codec = try RouterSnapshotCodec<ThirteenthReviewRoute>(currentVersion: 1)
        let firstDeferral = RouterDeferralID()
        let secondDeferral = RouterDeferralID()
        let store = RouterStore<ThirteenthReviewRoute>(configuration: .init(policies: [
            RouterPolicy(name: "first") { transition in
                transition.context.source == .restoration
                    ? .deferRequest(firstDeferral)
                    : .allow
            },
            RouterPolicy(name: "second") { transition in
                transition.context.source == .restoration
                    ? .deferRequest(secondDeferral)
                    : .allow
            },
        ]))
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: ThirteenthReviewSnapshotStorage(
                data: try codec.encode(.rootStack(path: [.first]))
            )
        )

        _ = try await driver.activate()
        guard case .deferred = await store.resumeDeferred(firstDeferral) else {
            Issue.record("Expected the restore request to defer a second time")
            return
        }
        #expect(store.deferredTransitions.map(\.id) == [secondDeferral])

        driver.stop()
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("An unrelated restoration rejection cannot release the active restore root")
    func unrelatedRestorationEventDoesNotReleaseActiveRoot() async throws {
        let gate = ThirteenthReviewPolicyGate()
        let codec = try RouterSnapshotCodec<ThirteenthReviewRoute>(currentVersion: 1)
        let store = RouterStore<ThirteenthReviewRoute>(configuration: .init(
            policies: [RouterPolicy(name: "restore") { transition in
                if transition.context.source == .restoration {
                    await gate.suspend()
                }
                return .allow
            }],
            schedulingPolicy: .rejectWhileBusy
        ))
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: ThirteenthReviewSnapshotStorage(
                data: try codec.encode(.rootStack(path: [.first]))
            )
        )

        let activation = Task { try await driver.activate() }
        await gate.waitUntilEntered()
        guard case .rejected(_, _, _, .busy) = await store.perform(
            .push(.second),
            context: .init(source: .restoration)
        ) else {
            Issue.record("Expected the unrelated restoration request to be rejected as busy")
            gate.release()
            _ = try? await activation.value
            return
        }

        driver.stop()
        await Task.yield()
        let next = await store.perform(.push(.third))
        if case .rejected(_, _, _, .busy) = next {
            Issue.record("An unrelated restoration event released cancellation ownership")
        }

        gate.release()
        _ = try? await activation.value
        #expect(store.state.root == .stack(path: [.third]))
    }
}

#if canImport(AppKit)
@MainActor
private final class ThirteenthReviewRenderObservations {
    var paths: [Int: [ThirteenthReviewRoute]] = [:]
    var sceneEvents: [RouterSceneDriverEvent<ThirteenthReviewRoute>] = []
}

@MainActor
private struct ThirteenthReviewRouterReader: View {
    @EnvironmentRouterState(ThirteenthReviewRoute.self) private var router
    let generation: Int
    let observations: ThirteenthReviewRenderObservations

    var body: some View {
        ThirteenthReviewCapture(
            generation: generation,
            path: router.path,
            observations: observations
        )
    }
}

private struct ThirteenthReviewCapture: NSViewRepresentable {
    let generation: Int
    let path: [ThirteenthReviewRoute]
    let observations: ThirteenthReviewRenderObservations

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        observations.paths[generation] = path
    }
}

@MainActor
private struct ThirteenthReviewSceneRoot: View {
    let store: RouterStore<ThirteenthReviewRoute>
    let generation: Int
    let observations: ThirteenthReviewRenderObservations

    var body: some View {
        RouterSceneDriver(
            store: store,
            onEvent: { observations.sceneEvents.append($0) }
        ) {
            ThirteenthReviewCapture(
                generation: generation,
                path: [],
                observations: observations
            )
        }
    }
}

@MainActor
private struct ThirteenthReviewRestorationRoot: View {
    let driver: RouterRestorationDriver<ThirteenthReviewRoute>
    let generation: Int
    let observations: ThirteenthReviewRenderObservations

    var body: some View {
        ThirteenthReviewCapture(
            generation: generation,
            path: [],
            observations: observations
        )
        .routerStateRestoration(driver)
    }
}

@Suite("Thirteenth review native host regressions")
@MainActor
struct RouterThirteenthReviewNativeHostTests {
    @Test("Replacing an externally supplied store updates host authority")
    func externalStoreReplacement() async throws {
        let first = RouterStore<ThirteenthReviewRoute>()
        let second = RouterStore<ThirteenthReviewRoute>(initialPath: [.second])
        let observations = ThirteenthReviewRenderObservations()
        let host = NSHostingView(rootView: RouterHost(store: first) {
            ThirteenthReviewRouterReader(generation: 0, observations: observations)
        })
        let window = makeWindow(host)
        await render(host)
        #expect(observations.paths[0] == [])

        host.rootView = RouterHost(store: second) {
            ThirteenthReviewRouterReader(generation: 1, observations: observations)
        }
        await render(host)
        #expect(observations.paths[1] == [.second])
        _ = await first.perform(.push(.third))
        await render(host)
        #expect(observations.paths[1] == [.second])
        window.contentView = nil
    }

    @Test("Replacing a restoration modifier detaches its previous driver")
    func restorationDriverReplacement() async throws {
        let codec = try RouterSnapshotCodec<ThirteenthReviewRoute>(currentVersion: 1)
        let first = RouterRestorationDriver(
            store: RouterStore<ThirteenthReviewRoute>(),
            codec: codec,
            storage: ThirteenthReviewSnapshotStorage(data: nil)
        )
        let second = RouterRestorationDriver(
            store: RouterStore<ThirteenthReviewRoute>(),
            codec: codec,
            storage: ThirteenthReviewSnapshotStorage(data: nil)
        )
        let observations = ThirteenthReviewRenderObservations()
        let host = NSHostingView(rootView: ThirteenthReviewRestorationRoot(
            driver: first,
            generation: 0,
            observations: observations
        ))
        let window = makeWindow(host)
        await render(host)
        for _ in 0..<100 where first.status == .inactive {
            await Task.yield()
        }
        #expect(first.status == .active)

        host.rootView = ThirteenthReviewRestorationRoot(
            driver: second,
            generation: 1,
            observations: observations
        )
        await render(host)
        for _ in 0..<100 where first.status != .inactive || second.status == .inactive {
            await Task.yield()
        }

        #expect(first.status == .inactive)
        #expect(second.status == .active)
        window.contentView = nil
        second.stop()
    }

    @Test("A scene driver reconciles a replacement store at the same revision")
    func sceneStoreReplacementAtSameRevision() async throws {
        let first = RouterStore<ThirteenthReviewRoute>()
        let second = RouterStore(
            initialState: try RouterState<ThirteenthReviewRoute>(
                windows: [.init(route: .second)]
            )
        )
        let observations = ThirteenthReviewRenderObservations()
        let host = NSHostingView(rootView: ThirteenthReviewSceneRoot(
            store: first,
            generation: 0,
            observations: observations
        ))
        let window = makeWindow(host)
        await render(host)

        host.rootView = ThirteenthReviewSceneRoot(
            store: second,
            generation: 1,
            observations: observations
        )
        await render(host)

        #expect(observations.paths.keys.contains(1))
        #expect(observations.sceneEvents.contains {
            guard case .openedWindow(let window, _) = $0 else { return false }
            return window.route == .second
        })
        window.contentView = nil
    }

    @Test("A same-ID replacement reconciles both native window lifetimes")
    func sameIDWindowReplacement() async throws {
        let id = UUID()
        let store = RouterStore(
            initialState: try RouterState<ThirteenthReviewRoute>(
                windows: [.init(id: id, route: .first)]
            )
        )
        let observations = ThirteenthReviewRenderObservations()
        let host = NSHostingView(rootView: ThirteenthReviewSceneRoot(
            store: store,
            generation: 0,
            observations: observations
        ))
        let window = makeWindow(host)
        await render(host)

        let initialOpenCount = observations.sceneEvents.filter {
            guard case .openedWindow = $0 else { return false }
            return true
        }.count
        _ = await store.perform(.push(.third))
        await render(host)
        #expect(observations.sceneEvents.filter {
            guard case .openedWindow = $0 else { return false }
            return true
        }.count == initialOpenCount)

        _ = await store.perform(.dismissWindow(id))
        _ = await store.perform(.openWindow(.init(id: id, route: .second)))
        await render(host)

        #expect(observations.sceneEvents.contains {
            guard case .dismissedWindow(let window, _) = $0 else { return false }
            return window.id == id && window.route == .first
        })
        #expect(observations.sceneEvents.contains {
            guard case .openedWindow(let window, _) = $0 else { return false }
            return window.id == id && window.route == .second
        })
        window.contentView = nil
    }

    private func makeWindow<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    private func render<V: View>(_ host: NSHostingView<V>) async {
        host.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        host.layoutSubtreeIfNeeded()
    }
}
#endif
