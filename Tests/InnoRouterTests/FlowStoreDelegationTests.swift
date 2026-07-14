// MARK: - FlowStoreDelegationTests.swift
// InnoRouterTests - FlowStore delegation to inner navigation/modal stores
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum FlowDelegationRoute: Route {
    case home
    case detail
    case share
    case paywall
    case profile(id: String)
}

private let flowDelegationProfileCase = CasePath<FlowDelegationRoute, String>(
    embed: FlowDelegationRoute.profile(id:),
    extract: {
        if case .profile(let id) = $0 {
            return id
        }
        return nil
    }
)

@MainActor
private final class FlowDelegationRecordingReconciler<R: Route>: NavigationPathReconciling {
    var calls: [(old: [R], new: [R])] = []

    nonisolated init() {}

    func reconcile(
        from oldPath: [R],
        to newPath: [R],
        resolveMismatch: @MainActor ([R], [R]) -> NavigationPathMismatchResolution<R>,
        execute: @MainActor (NavigationCommand<R>) -> Void,
        executeBatch: @MainActor ([NavigationCommand<R>]) -> Void
    ) {
        calls.append((old: oldPath, new: newPath))
        NavigationPathReconciler<R>().reconcile(
            from: oldPath,
            to: newPath,
            resolveMismatch: resolveMismatch,
            execute: execute,
            executeBatch: executeBatch
        )
    }
}

@MainActor
private final class ReentrantFlowEventObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var events: [FlowEvent<FlowDelegationRoute>] = []
    var pathAtFirstNavigationEvent: [RouteStep<FlowDelegationRoute>]?
    private var didReenter = false

    func handle(_ event: FlowEvent<FlowDelegationRoute>) {
        events.append(event)
        guard !didReenter, case .navigation(.changed) = event else { return }
        didReenter = true
        pathAtFirstNavigationEvent = store?.path
        store?.send(.push(.detail))
    }
}

@MainActor
private final class ReentrantModalFlowEventObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var events: [FlowEvent<FlowDelegationRoute>] = []
    var pathAtReplacementEvent: [RouteStep<FlowDelegationRoute>]?
    private var didReenter = false

    func handle(_ event: FlowEvent<FlowDelegationRoute>) {
        events.append(event)
        guard !didReenter, case .modal(.replaced) = event else { return }
        didReenter = true
        pathAtReplacementEvent = store?.path
        store?.send(.dismiss)
    }
}

@MainActor
private final class ReentrantInnerNavigationObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var flowEvents: [FlowEvent<FlowDelegationRoute>] = []
    private var didReenter = false

    func handleNavigation(_ event: NavigationEvent<FlowDelegationRoute>) {
        guard !didReenter, case .changed = event else { return }
        didReenter = true
        store?.send(.dismiss)
    }
}

@MainActor
private final class ReentrantInnerPathMismatchObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var flowEvents: [FlowEvent<FlowDelegationRoute>] = []
    private var didReenter = false

    func handleNavigation(_ event: NavigationEvent<FlowDelegationRoute>) {
        guard !didReenter, case .pathMismatch = event else { return }
        didReenter = true
        store?.send(.push(.detail))
    }
}

@MainActor
private final class ReentrantInnerNavigationTelemetryObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var flowEvents: [FlowEvent<FlowDelegationRoute>] = []
    private var didReenter = false

    func record(_ event: NavigationEvent<FlowDelegationRoute>) {
        guard !didReenter, case .changed = event else { return }
        didReenter = true
        store?.send(.push(.detail))
    }
}

@MainActor
private final class ReentrantInnerModalTelemetryObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var flowEvents: [FlowEvent<FlowDelegationRoute>] = []
    var pathAtReplacementTelemetry: [RouteStep<FlowDelegationRoute>]?
    private var didReenter = false

    func record(_ event: ModalEvent<FlowDelegationRoute>) {
        guard !didReenter, case .replaced = event else { return }
        didReenter = true
        pathAtReplacementTelemetry = store?.path
        store?.send(.dismiss)
    }
}

@MainActor
private final class ReentrantFlowApplyObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var events: [FlowEvent<FlowDelegationRoute>] = []
    var result: FlowPlanApplyResult<FlowDelegationRoute>?

    func handle(_ event: FlowEvent<FlowDelegationRoute>) {
        events.append(event)
        guard result == nil, case .navigation(.changed) = event else { return }
        result = store?.apply(FlowPlan(steps: [.push(.detail)]))
    }
}

@MainActor
private final class ReentrantInnerApplyObserver {
    weak var store: FlowStore<FlowDelegationRoute>?
    var result: FlowPlanApplyResult<FlowDelegationRoute>?

    func handle(_ event: NavigationEvent<FlowDelegationRoute>) {
        guard result == nil, case .changed = event else { return }
        result = store?.apply(FlowPlan(steps: [.push(.detail)]))
    }
}

@Suite("FlowStore Delegation Tests")
struct FlowStoreDelegationTests {

    @Test("reentrant onEvent observes the current path and preserves transition order")
    @MainActor
    func reentrantOnEventSeesCurrentPath() async {
        let observer = ReentrantFlowEventObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(onEvent: { event in
                observer.handle(event)
            })
        )
        observer.store = store
        var iterator = store.events.makeAsyncIterator()

        store.navigationStore.send(.go(.home))

        let callbackEvents = observer.events
        var streamEvents: [FlowEvent<FlowDelegationRoute>] = []
        for _ in callbackEvents.indices {
            guard let event = await iterator.next() else {
                Issue.record("FlowStore.events ended before matching the reentrant onEvent sequence")
                return
            }
            streamEvents.append(event)
        }

        #expect(observer.pathAtFirstNavigationEvent == [.push(.home)])
        #expect(store.navigationStore.state.path == [.home, .detail])
        #expect(store.path == [.push(.home), .push(.detail)])
        #expect(callbackEvents == streamEvents)
        #expect(callbackEvents.count == 4)

        guard case .navigation(.changed(let firstOld, let firstNew)) = callbackEvents[0] else {
            Issue.record("Expected the outer navigation change first")
            return
        }
        #expect(firstOld.path.isEmpty)
        #expect(firstNew.path == [.home])

        guard case .pathChanged(let firstOldPath, let firstNewPath) = callbackEvents[1] else {
            Issue.record("Expected the outer path transition second")
            return
        }
        #expect(firstOldPath.isEmpty)
        #expect(firstNewPath == [.push(.home)])

        guard case .navigation(.changed(let secondOld, let secondNew)) = callbackEvents[2] else {
            Issue.record("Expected the reentrant navigation change third")
            return
        }
        #expect(secondOld.path == [.home])
        #expect(secondNew.path == [.home, .detail])

        guard case .pathChanged(let secondOldPath, let secondNewPath) = callbackEvents[3] else {
            Issue.record("Expected the reentrant path transition last")
            return
        }
        #expect(secondOldPath == [.push(.home)])
        #expect(secondNewPath == [.push(.home), .push(.detail)])
    }

    @Test("reentrant modal replacement preserves wrapped-event ordering and current path")
    @MainActor
    func reentrantModalReplacementSeesCurrentPath() async {
        let observer = ReentrantModalFlowEventObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(onEvent: { event in
                observer.handle(event)
            })
        )
        observer.store = store
        store.send(.presentSheet(.share))
        observer.events.removeAll()
        var iterator = store.events.makeAsyncIterator()

        store.modalStore.replaceCurrent(.paywall, style: .fullScreenCover)

        let callbackEvents = observer.events
        var streamEvents: [FlowEvent<FlowDelegationRoute>] = []
        for _ in callbackEvents.indices {
            guard let event = await iterator.next() else {
                Issue.record("FlowStore.events ended before matching the reentrant modal sequence")
                return
            }
            streamEvents.append(event)
        }

        #expect(observer.pathAtReplacementEvent == [.cover(.paywall)])
        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.path.isEmpty)
        #expect(callbackEvents == streamEvents)
        #expect(callbackEvents.count == 6)

        guard case .modal(.replaced(let old, let new)) = callbackEvents[0] else {
            Issue.record("Expected replacement first")
            return
        }
        #expect(old.route == .share)
        #expect(new.route == .paywall)

        guard case .modal(.commandIntercepted(_, let replacementResult)) = callbackEvents[1],
              case .executed(.replaceCurrent) = replacementResult else {
            Issue.record("Expected replacement interception second")
            return
        }
        guard case .pathChanged(let replacementOldPath, let replacementNewPath) = callbackEvents[2] else {
            Issue.record("Expected replacement path transition third")
            return
        }
        #expect(replacementOldPath == [.sheet(.share)])
        #expect(replacementNewPath == [.cover(.paywall)])

        guard case .modal(.dismissed(let dismissed, _)) = callbackEvents[3] else {
            Issue.record("Expected reentrant dismissal fourth")
            return
        }
        #expect(dismissed.route == .paywall)
        guard case .modal(.commandIntercepted(_, let dismissalResult)) = callbackEvents[4],
              case .executed(.dismissCurrent) = dismissalResult else {
            Issue.record("Expected dismissal interception fifth")
            return
        }
        guard case .pathChanged(let dismissalOldPath, let dismissalNewPath) = callbackEvents[5] else {
            Issue.record("Expected dismissal path transition last")
            return
        }
        #expect(dismissalOldPath == [.cover(.paywall)])
        #expect(dismissalNewPath.isEmpty)
    }

    @Test("inner navigation callback waits for the outer Flow mutation to finish")
    @MainActor
    func innerNavigationReentryWaitsForOuterMutation() {
        let observer = ReentrantInnerNavigationObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                navigation: .init(onEvent: { event in
                    observer.handleNavigation(event)
                }),
                onEvent: { event in
                    observer.flowEvents.append(event)
                }
            )
        )
        observer.store = store

        store.send(.reset([.push(.home), .sheet(.share)]))

        #expect(store.navigationStore.state.path == [.home])
        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.path == [.push(.home)])

        let pathChanges: [(
            old: [RouteStep<FlowDelegationRoute>],
            new: [RouteStep<FlowDelegationRoute>]
        )] = observer.flowEvents.compactMap { event in
            guard case .pathChanged(let old, let new) = event else { return nil }
            return (old, new)
        }
        #expect(pathChanges.count == 2)
        #expect(pathChanges[0].old.isEmpty)
        #expect(pathChanges[0].new == [.push(.home), .sheet(.share)])
        #expect(pathChanges[1].old == [.push(.home), .sheet(.share)])
        #expect(pathChanges[1].new == [.push(.home)])
    }

    @Test("inner path-mismatch reentry waits for reconciliation to finish")
    @MainActor
    func innerPathMismatchReentryWaitsForReconciliation() {
        let observer = ReentrantInnerPathMismatchObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                navigation: .init(onEvent: { event in
                    observer.handleNavigation(event)
                }),
                onEvent: { event in
                    observer.flowEvents.append(event)
                }
            )
        )
        observer.store = store
        store.send(.push(.home))
        observer.flowEvents.removeAll()

        store.navigationStore.pathBinding.wrappedValue = [.paywall]

        #expect(store.navigationStore.state.path == [.paywall, .detail])
        #expect(store.path == [.push(.paywall), .push(.detail)])

        let changedPaths = observer.flowEvents.compactMap { event -> [FlowDelegationRoute]? in
            guard case .navigation(.changed(_, let newState)) = event else { return nil }
            return newState.path
        }
        #expect(changedPaths == [[.paywall], [.paywall, .detail]])
    }

    @Test("inner navigation telemetry reentry waits for wrapped flow events")
    @MainActor
    func innerNavigationTelemetryReentryPreservesOrder() {
        let observer = ReentrantInnerNavigationTelemetryObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                navigation: .init(
                    telemetrySink: AnyNavigationTelemetrySink { event in
                        observer.record(event)
                    }
                ),
                onEvent: { event in
                    observer.flowEvents.append(event)
                }
            )
        )
        observer.store = store

        store.navigationStore.send(.go(.home))

        #expect(store.path == [.push(.home), .push(.detail)])
        #expect(observer.flowEvents.count == 4)
        guard observer.flowEvents.count == 4 else { return }

        guard case .navigation(.changed(_, let outerState)) = observer.flowEvents[0] else {
            Issue.record("Expected the outer navigation change first")
            return
        }
        #expect(outerState.path == [.home])
        #expect(observer.flowEvents[1] == .pathChanged(old: [], new: [.push(.home)]))

        guard case .navigation(.changed(_, let reentrantState)) = observer.flowEvents[2] else {
            Issue.record("Expected the reentrant navigation change third")
            return
        }
        #expect(reentrantState.path == [.home, .detail])
        #expect(
            observer.flowEvents[3]
                == .pathChanged(
                    old: [.push(.home)],
                    new: [.push(.home), .push(.detail)]
                )
        )
    }

    @Test("inner modal telemetry reentry waits for replacement flow events")
    @MainActor
    func innerModalTelemetryReentryPreservesOrder() {
        let observer = ReentrantInnerModalTelemetryObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                modal: .init(
                    telemetrySink: AnyModalTelemetrySink { event in
                        observer.record(event)
                    }
                ),
                onEvent: { event in
                    observer.flowEvents.append(event)
                }
            )
        )
        observer.store = store
        store.send(.presentSheet(.share))
        observer.flowEvents.removeAll()

        store.modalStore.replaceCurrent(.paywall, style: .fullScreenCover)

        #expect(observer.pathAtReplacementTelemetry == [.cover(.paywall)])
        #expect(store.path.isEmpty)
        #expect(observer.flowEvents.count == 6)
        guard observer.flowEvents.count == 6 else { return }

        guard case .modal(.replaced) = observer.flowEvents[0] else {
            Issue.record("Expected replacement first")
            return
        }
        guard case .modal(.commandIntercepted) = observer.flowEvents[1] else {
            Issue.record("Expected replacement interception second")
            return
        }
        #expect(
            observer.flowEvents[2]
                == .pathChanged(old: [.sheet(.share)], new: [.cover(.paywall)])
        )
        guard case .modal(.dismissed) = observer.flowEvents[3] else {
            Issue.record("Expected the reentrant dismissal fourth")
            return
        }
        guard case .modal(.commandIntercepted) = observer.flowEvents[4] else {
            Issue.record("Expected dismissal interception fifth")
            return
        }
        #expect(
            observer.flowEvents[5]
                == .pathChanged(old: [.cover(.paywall)], new: [])
        )
    }

    @Test("reentrant Flow apply is rejected until Flow event delivery finishes")
    @MainActor
    func reentrantFlowApplyIsRejected() {
        let observer = ReentrantFlowApplyObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(onEvent: { event in
                observer.handle(event)
            })
        )
        observer.store = store

        store.navigationStore.send(.go(.home))

        #expect(observer.result == .rejected(currentPath: [.push(.home)], reason: .reentrantApply))
        #expect(store.path == [.push(.home)])
        #expect(observer.events.count == 2)
    }

    @Test("reentrant inner apply is rejected without mixing Flow plans")
    @MainActor
    func reentrantInnerApplyIsRejected() {
        let observer = ReentrantInnerApplyObserver()
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                navigation: .init(onEvent: { event in
                    observer.handle(event)
                })
            )
        )
        observer.store = store

        store.send(.reset([.push(.home), .sheet(.share)]))

        #expect(observer.result == .rejected(currentPath: [.push(.home)], reason: .reentrantApply))
        #expect(store.path == [.push(.home), .sheet(.share)])
    }

    @Test("push delegates to navigation store and updates state")
    @MainActor
    func pushDelegatesToNavigation() {
        let store = FlowStore<FlowDelegationRoute>()

        store.send(.push(.home))
        store.send(.push(.detail))

        #expect(store.navigationStore.state.path == [.home, .detail])
        #expect(store.path == [.push(.home), .push(.detail)])
    }

    @Test("presentSheet delegates to modal store with sheet style")
    @MainActor
    func presentSheetDelegatesToModal() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.push(.home))
        store.send(.presentSheet(.share))

        #expect(store.modalStore.currentPresentation?.route == .share)
        #expect(store.modalStore.currentPresentation?.style == .sheet)
        #expect(store.path.last == .sheet(.share))
    }

    @Test("presentCover delegates to modal store with fullScreenCover style")
    @MainActor
    func presentCoverDelegatesToModal() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.presentCover(.paywall))

        #expect(store.modalStore.currentPresentation?.style == .fullScreenCover)
        #expect(store.path == [.cover(.paywall)])
    }

    @Test("direct modal replacement updates flow path")
    @MainActor
    func directModalReplacementUpdatesFlowPath() {
        let changes = Mutex<[([RouteStep<FlowDelegationRoute>], [RouteStep<FlowDelegationRoute>])]>([])
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .pathChanged(let oldPath, let newPath) = event else { return }
                    changes.withLock { $0.append((oldPath, newPath)) }
                }
            )
        )

        store.send(.presentSheet(.share))
        store.modalStore.replaceCurrent(.paywall, style: .fullScreenCover)

        #expect(store.modalStore.currentPresentation?.route == .paywall)
        #expect(store.modalStore.currentPresentation?.style == .fullScreenCover)
        #expect(store.path == [.cover(.paywall)])

        let capturedChanges = changes.withLock { $0 }
        #expect(capturedChanges.map { $0.1 } == [[.sheet(.share)], [.cover(.paywall)]])
        #expect(capturedChanges.last?.0 == [.sheet(.share)])
    }

    @Test("modal binding replacement updates associated route in flow path")
    @MainActor
    func modalBindingReplacementUpdatesFlowPath() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.presentSheet(.profile(id: "1")))

        store.modalStore.binding(case: flowDelegationProfileCase, style: .sheet).wrappedValue = "2"

        #expect(store.modalStore.currentPresentation?.route == .profile(id: "2"))
        #expect(store.modalStore.currentPresentation?.style == .sheet)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(store.path == [.sheet(.profile(id: "2"))])
    }

    @Test("modal middleware rewrite updates flow path to committed presentation style")
    @MainActor
    func modalRewriteProjectsCommittedStyle() {
        let middleware = AnyModalMiddleware<FlowDelegationRoute>(
            willExecute: { command, _, _ in
                if case .present(let presentation) = command, presentation.style == .sheet {
                    return .proceed(
                        .present(
                            ModalPresentation(
                                id: presentation.id,
                                route: presentation.route,
                                style: .fullScreenCover
                            )
                        )
                    )
                }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                modal: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.presentSheet(.share))

        #expect(store.modalStore.currentPresentation?.style == .fullScreenCover)
        #expect(store.path == [.cover(.share)])
    }

    @Test("pop delegates to navigation and trims path tail")
    @MainActor
    func popDelegatesToNavigation() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.push(.home))
        store.send(.push(.detail))
        store.send(.pop)

        #expect(store.navigationStore.state.path == [.home])
        #expect(store.path == [.push(.home)])
    }

    @Test("dismiss delegates to modal store and trims modal tail")
    @MainActor
    func dismissDelegatesToModal() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.push(.home))
        store.send(.presentSheet(.share))
        store.send(.dismiss)

        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.path == [.push(.home)])
    }

    @Test("dismiss keeps promoted queued modal as new path tail")
    @MainActor
    func dismissKeepsPromotedQueuedModalTail() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.push(.home))
        store.send(.presentSheet(.share))
        store.send(.presentSheet(.paywall))

        store.send(.dismiss)

        #expect(store.modalStore.currentPresentation?.route == .paywall)
        #expect(store.modalStore.currentPresentation?.style == .sheet)
        #expect(store.path == [.push(.home), .sheet(.paywall)])
    }

    @Test("reset replaces navigation prefix and applies modal tail")
    @MainActor
    func resetReplacesStacksAndPresentsModal() {
        let store = FlowStore<FlowDelegationRoute>()
        store.send(.push(.home))
        store.send(.push(.detail))

        store.send(.reset([.push(.home), .sheet(.share)]))

        #expect(store.navigationStore.state.path == [.home])
        #expect(store.modalStore.currentPresentation?.route == .share)
        #expect(store.path == [.push(.home), .sheet(.share)])
    }

    @Test("navigation middleware rewrite updates flow path to committed stack")
    @MainActor
    func navigationRewriteProjectsCommittedStack() {
        let middleware = AnyNavigationMiddleware<FlowDelegationRoute>(
            willExecute: { command, _ in
                if case .push(.detail) = command {
                    return .proceed(.replace([.home, .paywall]))
                }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowDelegationRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.push(.detail))

        #expect(store.navigationStore.state.path == [.home, .paywall])
        #expect(store.path == [.push(.home), .push(.paywall)])
    }

    @Test("inner navigation onEvent still fires when caller supplies an observer")
    @MainActor
    func userNavigationChangedEventStillFires() {
        let changes = Mutex<Int>(0)
        let config = FlowStoreConfiguration<FlowDelegationRoute>(
            navigation: .init(
                onEvent: { event in
                    guard case .changed = event else { return }
                    changes.withLock { $0 += 1 }
                }
            )
        )
        let store = FlowStore<FlowDelegationRoute>(configuration: config)

        store.send(.push(.home))
        store.send(.push(.detail))

        #expect(changes.withLock { $0 } == 2)
    }

    @Test("inner navigation onEvent receives pathMismatch and flow path stays in sync")
    @MainActor
    func userNavigationPathMismatchEventStillFires() {
        let mismatches = Mutex<[NavigationPathMismatchEvent<FlowDelegationRoute>]>([])
        let config = FlowStoreConfiguration<FlowDelegationRoute>(
            navigation: .init(
                onEvent: { event in
                    guard case .pathMismatch(let mismatch) = event else { return }
                    mismatches.withLock { $0.append(mismatch) }
                }
            )
        )
        let store = FlowStore<FlowDelegationRoute>(configuration: config)

        store.send(.push(.home))
        store.navigationStore.pathBinding.wrappedValue = [.detail]

        let captured = mismatches.withLock { $0 }
        #expect(captured.count == 1)
        #expect(captured.first?.oldPath == [.home])
        #expect(captured.first?.newPath == [.detail])
        #expect(store.navigationStore.state.path == [.detail])
        #expect(store.path == [.push(.detail)])
    }

    @Test("inner navigation receives FlowStoreConfiguration path reconciler")
    @MainActor
    func customPathReconcilerPropagatesToInnerNavigationStore() {
        let recorder = FlowDelegationRecordingReconciler<FlowDelegationRoute>()
        let config = FlowStoreConfiguration<FlowDelegationRoute>(
            navigation: .init(pathReconciler: recorder)
        )
        let store = FlowStore<FlowDelegationRoute>(configuration: config)

        store.send(.push(.home))
        store.navigationStore.pathBinding.wrappedValue = [.home, .detail]

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.old == [.home])
        #expect(recorder.calls.first?.new == [.home, .detail])
        #expect(store.navigationStore.state.path == [.home, .detail])
        #expect(store.path == [.push(.home), .push(.detail)])
    }

    @Test("inner modal onEvent receives presented when caller supplies an observer")
    @MainActor
    func userModalPresentedEventStillFires() {
        let presented = Mutex<[FlowDelegationRoute]>([])
        let config = FlowStoreConfiguration<FlowDelegationRoute>(
            modal: .init(
                onEvent: { event in
                    guard case .presented(let presentation) = event else { return }
                    presented.withLock { $0.append(presentation.route) }
                }
            )
        )
        let store = FlowStore<FlowDelegationRoute>(configuration: config)

        store.send(.presentSheet(.share))

        #expect(presented.withLock { $0 } == [.share])
    }

    @Test("inner modal receives FlowStoreConfiguration queue cancellation policy")
    @MainActor
    func queueCancellationPolicyPropagatesToInnerModalStore() {
        let gate = AnyModalMiddleware<FlowDelegationRoute>(
            willExecute: { command, _, _ in
                if case .dismissAll = command {
                    return .cancel(.middleware(debugName: "dismiss-gate", command: command))
                }
                return .proceed(command)
            }
        )
        let config = FlowStoreConfiguration<FlowDelegationRoute>(
            modal: .init(
                middlewares: [.init(middleware: gate, debugName: "dismiss-gate")],
                queueCancellationPolicy: .dropQueued
            )
        )
        let store = FlowStore<FlowDelegationRoute>(configuration: config)

        store.send(.presentSheet(.share))
        store.send(.presentSheet(.paywall))
        _ = store.modalStore.execute(.dismissAll)

        #expect(store.modalStore.currentPresentation?.route == .share)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(store.path == [.sheet(.share)])
    }
}
