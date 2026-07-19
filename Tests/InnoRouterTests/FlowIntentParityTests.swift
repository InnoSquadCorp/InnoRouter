// MARK: - FlowIntentParityTests.swift
// InnoRouterTests - navigation/modal parity on the unified FlowStore path
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum FlowParityRoute: Route {
    case root
    case first
    case second
    case third
    case missing
    case modal
    case queuedModal
    case rewritten
}

@MainActor
private final class FlowParityReentrantObserver {
    weak var store: FlowStore<FlowParityRoute>?
    var changedPaths: [[RouteStep<FlowParityRoute>]] = []
    private var didQueueParityIntents = false

    func handle(_ event: FlowEvent<FlowParityRoute>) {
        if case .pathChanged(_, let newPath) = event {
            changedPaths.append(newPath)
        }

        guard !didQueueParityIntents,
              case .navigation(.changed(_, let newStack)) = event,
              newStack.path == [.root]
        else { return }

        didQueueParityIntents = true
        store?.send(.pushMany([.first, .second]))
        store?.send(.popCount(1))
    }
}

@MainActor
private final class FlowParityReentrantNavigationMiddleware: NavigationMiddleware {
    typealias RouteType = FlowParityRoute

    weak var store: FlowStore<FlowParityRoute>?
    private(set) var observedCommands: [NavigationCommand<FlowParityRoute>] = []
    private var didReenter = false

    func willExecute(
        _ command: NavigationCommand<FlowParityRoute>,
        state: RouteStack<FlowParityRoute>
    ) -> NavigationInterception<FlowParityRoute> {
        observedCommands.append(command)

        if !didReenter, command == .push(.root) {
            didReenter = true
            store?.send(.push(.first))
            store?.send(.push(.second))
        }

        return .proceed(command)
    }

    func didExecute(
        _ command: NavigationCommand<FlowParityRoute>,
        result: NavigationResult<FlowParityRoute>,
        state: RouteStack<FlowParityRoute>
    ) -> NavigationResult<FlowParityRoute> {
        result
    }
}

@MainActor
private final class FlowParityResetNavigationMiddleware:
    NavigationMiddleware,
    NavigationMiddlewareDiscardCleanup
{
    typealias RouteType = FlowParityRoute

    private(set) var finalized: [NavigationCommand<FlowParityRoute>] = []
    private(set) var discarded: [NavigationCommand<FlowParityRoute>] = []

    func willExecute(
        _ command: NavigationCommand<FlowParityRoute>,
        state: RouteStack<FlowParityRoute>
    ) -> NavigationInterception<FlowParityRoute> {
        .proceed(command)
    }

    func didExecute(
        _ command: NavigationCommand<FlowParityRoute>,
        result: NavigationResult<FlowParityRoute>,
        state: RouteStack<FlowParityRoute>
    ) -> NavigationResult<FlowParityRoute> {
        finalized.append(command)
        return result
    }

    func discardExecution(
        _ command: NavigationCommand<FlowParityRoute>,
        result: NavigationResult<FlowParityRoute>,
        state: RouteStack<FlowParityRoute>
    ) {
        discarded.append(command)
    }
}

private struct FlowParityModalLifecycleRecord: Equatable {
    let command: ModalCommand<FlowParityRoute>
    let currentRoute: FlowParityRoute?
    let queuedRoutes: [FlowParityRoute]
}

@MainActor
private final class FlowParityResetModalMiddleware:
    ModalMiddleware,
    ModalMiddlewareDiscardCleanup
{
    typealias RouteType = FlowParityRoute

    private(set) var finalized: [FlowParityModalLifecycleRecord] = []
    private(set) var discarded: [FlowParityModalLifecycleRecord] = []

    func willExecute(
        _ command: ModalCommand<FlowParityRoute>,
        currentPresentation: ModalPresentation<FlowParityRoute>?,
        queuedPresentations: [ModalPresentation<FlowParityRoute>]
    ) -> ModalInterception<FlowParityRoute> {
        if case .present(let presentation) = command,
           presentation.route == .rewritten {
            return .cancel(.middleware(debugName: "reset-modal-gate", command: command))
        }
        return .proceed(command)
    }

    func didExecute(
        _ command: ModalCommand<FlowParityRoute>,
        currentPresentation: ModalPresentation<FlowParityRoute>?,
        queuedPresentations: [ModalPresentation<FlowParityRoute>]
    ) {
        finalized.append(
            Self.record(
                command: command,
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            )
        )
    }

    func discardExecution(
        _ command: ModalCommand<FlowParityRoute>,
        currentPresentation: ModalPresentation<FlowParityRoute>?,
        queuedPresentations: [ModalPresentation<FlowParityRoute>]
    ) {
        discarded.append(
            Self.record(
                command: command,
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            )
        )
    }

    func resetRecords() {
        finalized.removeAll()
        discarded.removeAll()
    }

    private static func record(
        command: ModalCommand<FlowParityRoute>,
        currentPresentation: ModalPresentation<FlowParityRoute>?,
        queuedPresentations: [ModalPresentation<FlowParityRoute>]
    ) -> FlowParityModalLifecycleRecord {
        FlowParityModalLifecycleRecord(
            command: command,
            currentRoute: currentPresentation?.route,
            queuedRoutes: queuedPresentations.map(\.route)
        )
    }
}

@MainActor
private final class FlowParityModalCancellationPolicyReentry {
    weak var store: FlowStore<FlowParityRoute>?
    private var didQueueIntents = false

    func resolve(
        command: ModalCommand<FlowParityRoute>,
        reason: ModalCancellationReason<FlowParityRoute>
    ) -> ModalQueueCancellationPolicy<FlowParityRoute>.Action {
        if !didQueueIntents {
            didQueueIntents = true
            store?.send(.dismiss)
            store?.send(.presentSheet(.rewritten))
        }
        return .dropQueued
    }
}

@Suite("FlowIntent Navigation/Modal Parity Tests")
struct FlowIntentParityTests {

    @Test("pushMany commits one pushAll preview and one projected transition")
    @MainActor
    func pushManyCommitsThroughOnePreview() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let events = Mutex<[FlowEvent<FlowParityRoute>]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)]),
                onEvent: { event in events.withLock { $0.append(event) } }
            )
        )

        store.send(.pushMany([.root, .first, .second]))

        #expect(store.path == [.push(.root), .push(.first), .push(.second)])
        #expect(store.navigationStore.state.path == [.root, .first, .second])
        #expect(commands.withLock { $0 } == [.pushAll([.root, .first, .second])])
        #expect(events.withLock { captured in
            captured.filter { if case .navigation(.changed) = $0 { true } else { false } }.count
        } == 1)
        #expect(events.withLock { captured in
            captured.filter { if case .pathChanged = $0 { true } else { false } }.count
        } == 1)
    }

    @Test("single pushMany uses the same push command as NavigationStore goMany")
    @MainActor
    func singlePushManyUsesPushCommand() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.pushMany([.root]))

        #expect(store.path == [.push(.root)])
        #expect(commands.withLock { $0 } == [.push(.root)])
    }

    @Test("empty pushMany is a no-op even with a modal; non-empty pushMany is rejected")
    @MainActor
    func pushManyModalTailBehavior() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let rejections = Mutex<[(FlowIntent<FlowParityRoute>, FlowRejectionReason)]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .sheet(.modal)],
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)]),
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )

        store.send(.pushMany([]))
        store.send(.pushMany([.first, .second]))

        #expect(store.path == [.push(.root), .sheet(.modal)])
        #expect(commands.withLock { $0.isEmpty })
        #expect(rejections.withLock { $0.count } == 1)
        #expect(rejections.withLock { $0.first?.0 } == .pushMany([.first, .second]))
        #expect(rejections.withLock { $0.first?.1 } == .pushBlockedByModalTail)
    }

    @Test("popCount, popTo, and popToRoot mutate the navigation prefix")
    @MainActor
    func popParityMutatesNavigationPrefix() {
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .push(.first), .push(.second), .push(.third)]
        )

        store.send(.popCount(2))
        #expect(store.path == [.push(.root), .push(.first)])

        store.send(.pushMany([.second, .third, .first]))
        store.send(.popTo(.second))
        #expect(store.path == [.push(.root), .push(.first), .push(.second)])

        store.send(.popToRoot)
        #expect(store.path.isEmpty)
        #expect(store.navigationStore.state.path.isEmpty)
    }

    @Test("full-depth popCount normalizes to popToRoot")
    @MainActor
    func fullDepthPopCountUsesPopToRoot() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .push(.first), .push(.second)],
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.popCount(3))

        #expect(store.path.isEmpty)
        #expect(commands.withLock { $0 } == [.popToRoot])
    }

    @Test("invalid popCount and missing popTo preserve state after preview")
    @MainActor
    func invalidPopParityPreservesState() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let pathChanges = Mutex<Int>(0)
        let rejections = Mutex<[FlowRejectionReason]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .push(.first)],
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)]),
                onEvent: { event in
                    switch event {
                    case .pathChanged:
                        pathChanges.withLock { $0 += 1 }
                    case .intentRejected(_, let reason):
                        rejections.withLock { $0.append(reason) }
                    default:
                        break
                    }
                }
            )
        )

        store.send(.popCount(0))
        store.send(.popCount(-1))
        store.send(.popCount(3))
        store.send(.popTo(.missing))

        #expect(store.path == [.push(.root), .push(.first)])
        #expect(pathChanges.withLock { $0 } == 0)
        #expect(rejections.withLock { $0 } == Array(repeating: .navigationExecutionFailed, count: 4))
        #expect(commands.withLock { $0 } == [
            .popCount(0),
            .popCount(-1),
            .popCount(3),
            .popTo(.missing),
        ])
    }

    @Test("empty pop and dismiss attempts still cross their middleware boundaries")
    @MainActor
    func emptyAttemptsReachMiddleware() {
        let navigationCommands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let modalCommands = Mutex<[ModalCommand<FlowParityRoute>]>([])
        let navigationMiddleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                navigationCommands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let modalMiddleware = AnyModalMiddleware<FlowParityRoute>(
            willExecute: { command, _, _ in
                modalCommands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: navigationMiddleware)]),
                modal: .init(middlewares: [.init(middleware: modalMiddleware)])
            )
        )

        store.send(.pop)
        store.send(.popCount(1))
        store.send(.popTo(.missing))
        store.send(.popToRoot)
        store.send(.dismiss)
        store.send(.dismissAll)

        #expect(store.path.isEmpty)
        #expect(navigationCommands.withLock { $0 } == [
            .pop,
            .popCount(1),
            .popTo(.missing),
            .popToRoot,
        ])
        #expect(modalCommands.withLock { $0 } == [
            .dismissCurrent(reason: .dismiss),
            .dismissAll,
        ])
    }

    @Test("empty pop can be rewritten by middleware")
    @MainActor
    func emptyPopMiddlewareRewriteCommits() {
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                guard command == .pop else { return .proceed(command) }
                return .proceed(.push(.rewritten))
            }
        )
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.pop)

        #expect(store.path == [.push(.rewritten)])
        #expect(store.navigationStore.state.path == [.rewritten])
    }

    @Test("all pop variants are no-ops while a modal tail is active")
    @MainActor
    func popParityDoesNotMutateBehindModal() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .push(.first), .sheet(.modal)],
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.pop)
        store.send(.popCount(1))
        store.send(.popTo(.root))
        store.send(.popToRoot)

        #expect(store.path == [.push(.root), .push(.first), .sheet(.modal)])
        #expect(store.navigationStore.state.path == [.root, .first])
        #expect(commands.withLock { $0.isEmpty })
    }

    @Test("dismissAll clears the active modal and queue through one modal preview")
    @MainActor
    func dismissAllClearsCurrentAndQueue() {
        let commands = Mutex<[ModalCommand<FlowParityRoute>]>([])
        let events = Mutex<[FlowEvent<FlowParityRoute>]>([])
        let middleware = AnyModalMiddleware<FlowParityRoute>(
            willExecute: { command, _, _ in
                commands.withLock { $0.append(command) }
                return .proceed(command)
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .sheet(.modal)],
            configuration: .init(
                modal: .init(middlewares: [.init(middleware: middleware)]),
                onEvent: { event in events.withLock { $0.append(event) } }
            )
        )
        store.send(.presentCover(.queuedModal))
        commands.withLock { $0.removeAll() }
        events.withLock { $0.removeAll() }

        store.send(.dismissAll)

        #expect(store.path == [.push(.root)])
        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(commands.withLock { $0 } == [.dismissAll])
        #expect(events.withLock { captured in
            captured.contains { if case .modal(.dismissed(_, reason: .dismissAll)) = $0 { true } else { false } }
        })
        #expect(events.withLock { captured in
            captured.contains { if case .modal(.queueChanged(_, let new)) = $0 { new.isEmpty } else { false } }
        })
        #expect(events.withLock { captured in
            captured.filter { if case .pathChanged = $0 { true } else { false } }.count
        } == 1)
    }

    @Test("dismissAll middleware cancellation preserves current and queued modals")
    @MainActor
    func dismissAllCancellationIsAtomic() {
        let rejections = Mutex<[(FlowIntent<FlowParityRoute>, FlowRejectionReason)]>([])
        let middleware = AnyModalMiddleware<FlowParityRoute>(
            willExecute: { command, _, _ in
                guard case .dismissAll = command else { return .proceed(command) }
                return .cancel(.middleware(debugName: "dismiss-all-gate", command: command))
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .sheet(.modal)],
            configuration: .init(
                modal: .init(
                    middlewares: [
                        .init(middleware: middleware, debugName: "dismiss-all-gate")
                    ]
                ),
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )
        store.send(.presentCover(.queuedModal))

        store.send(.dismissAll)

        #expect(store.path == [.push(.root), .sheet(.modal)])
        #expect(store.modalStore.currentPresentation?.route == .modal)
        #expect(store.modalStore.queuedPresentations.map(\.route) == [.queuedModal])
        #expect(rejections.withLock { $0.count } == 1)
        #expect(rejections.withLock { $0.first?.0 } == .dismissAll)
        #expect(rejections.withLock { $0.first?.1 }
            == .middlewareRejected(debugName: "dismiss-all-gate"))
    }

    @Test("navigation middleware can rewrite pushMany without escaping FlowStore")
    @MainActor
    func pushManyMiddlewareRewriteCommitsProjectedState() {
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                guard case .pushAll = command else { return .proceed(command) }
                return .proceed(.replace([.rewritten]))
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root)],
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)])
            )
        )

        store.send(.pushMany([.first, .second]))

        #expect(store.path == [.push(.rewritten)])
        #expect(store.navigationStore.state.path == [.rewritten])
    }

    @Test("navigation middleware cancellation rejects popCount without committing")
    @MainActor
    func popCountMiddlewareCancellationIsAtomic() {
        let rejections = Mutex<[(FlowIntent<FlowParityRoute>, FlowRejectionReason)]>([])
        let finalized = Mutex<[(NavigationCommand<FlowParityRoute>, NavigationResult<FlowParityRoute>)]>([])
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                guard case .popCount = command else { return .proceed(command) }
                return .cancel(.middleware(debugName: "pop-gate", command: command))
            },
            didExecute: { command, result, _ in
                finalized.withLock { $0.append((command, result)) }
                return result
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .push(.first), .push(.second)],
            configuration: .init(
                navigation: .init(
                    middlewares: [.init(middleware: middleware, debugName: "pop-gate")]
                ),
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )

        store.send(.popCount(2))

        #expect(store.path == [.push(.root), .push(.first), .push(.second)])
        #expect(rejections.withLock { $0.count } == 1)
        #expect(rejections.withLock { $0.first?.0 } == .popCount(2))
        #expect(rejections.withLock { $0.first?.1 }
            == .middlewareRejected(debugName: "pop-gate"))
        #expect(finalized.withLock { $0.count } == 1)
        #expect(finalized.withLock { $0.first?.0 } == .popCount(2))
        #expect(finalized.withLock { captured in
            guard case .cancelled = captured.first?.1 else { return false }
            return true
        })
    }

    @Test("cancelled push, pop, present, dismiss, and dismissAll finalize middleware lifecycle")
    @MainActor
    func cancelledSimpleAttemptsFinalizeLifecycle() {
        let finalizedNavigation = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let finalizedModal = Mutex<[ModalCommand<FlowParityRoute>]>([])
        let modalInterceptions = Mutex<Int>(0)
        let navigationMiddleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                .cancel(.middleware(debugName: "navigation-gate", command: command))
            },
            didExecute: { command, result, _ in
                finalizedNavigation.withLock { $0.append(command) }
                return result
            }
        )
        let modalMiddleware = AnyModalMiddleware<FlowParityRoute>(
            willExecute: { command, _, _ in
                .cancel(.middleware(debugName: "modal-gate", command: command))
            },
            didExecute: { command, _, _ in
                finalizedModal.withLock { $0.append(command) }
            }
        )
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: navigationMiddleware)]),
                modal: .init(middlewares: [.init(middleware: modalMiddleware)]),
                onEvent: { event in
                    guard case .modal(.commandIntercepted(_, result: .cancelled)) = event else {
                        return
                    }
                    modalInterceptions.withLock { $0 += 1 }
                }
            )
        )

        store.send(.push(.root))
        store.send(.pop)
        store.send(.presentSheet(.modal))
        store.send(.dismiss)
        store.send(.dismissAll)

        #expect(store.path.isEmpty)
        #expect(finalizedNavigation.withLock { $0 } == [.push(.root), .pop])
        #expect(finalizedModal.withLock { $0.count } == 3)
        #expect(finalizedModal.withLock { captured in
            guard captured.count == 3 else { return false }
            guard case .present = captured[0] else { return false }
            return captured[1] == .dismissCurrent(reason: .dismiss)
                && captured[2] == .dismissAll
        })
        #expect(modalInterceptions.withLock { $0 } == 3)
    }

    @Test("FlowStore modal cancellation applies dropQueued and emits queue change before rejection")
    @MainActor
    func modalCancellationAppliesQueuePolicy() {
        let events = Mutex<[FlowEvent<FlowParityRoute>]>([])
        let finalizedQueues = Mutex<[[FlowParityRoute]]>([])
        let middleware = AnyModalMiddleware<FlowParityRoute>(
            willExecute: { command, _, _ in
                guard case .dismissAll = command else { return .proceed(command) }
                return .cancel(.middleware(debugName: "dismiss-gate", command: command))
            },
            didExecute: { command, _, queue in
                guard case .dismissAll = command else { return }
                finalizedQueues.withLock { $0.append(queue.map(\.route)) }
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.sheet(.modal)],
            configuration: .init(
                modal: .init(
                    middlewares: [.init(middleware: middleware)],
                    queueCancellationPolicy: .dropQueued
                ),
                onEvent: { event in events.withLock { $0.append(event) } }
            )
        )
        store.send(.presentSheet(.queuedModal))
        events.withLock { $0.removeAll() }

        store.send(.dismissAll)

        #expect(store.path == [.sheet(.modal)])
        #expect(store.modalStore.currentPresentation?.route == .modal)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(finalizedQueues.withLock { $0 } == [[]])
        #expect(events.withLock { captured in
            captured.contains {
                if case .modal(.queueChanged(_, let newQueue)) = $0 {
                    return newQueue.isEmpty
                }
                return false
            }
        })
        #expect(events.withLock { captured in
            captured.contains {
                if case .modal(.commandIntercepted(.dismissAll, result: .cancelled)) = $0 {
                    return true
                }
                return false
            }
        })
        #expect(events.withLock { captured in
            captured.contains {
                if case .intentRejected(.dismissAll, .middlewareRejected(debugName: "dismiss-gate")) = $0 {
                    return true
                }
                return false
            }
        })
        #expect(events.withLock { captured in
            guard let queueIndex = captured.firstIndex(where: {
                if case .modal(.queueChanged) = $0 { return true }
                return false
            }), let interceptionIndex = captured.firstIndex(where: {
                if case .modal(.commandIntercepted(.dismissAll, result: .cancelled)) = $0 {
                    return true
                }
                return false
            }), let rejectionIndex = captured.firstIndex(where: {
                if case .intentRejected(.dismissAll, .middlewareRejected(debugName: "dismiss-gate")) = $0 {
                    return true
                }
                return false
            }) else { return false }

            return queueIndex < interceptionIndex && interceptionIndex < rejectionIndex
        })
    }

    @Test("modal cancellation policy reentrant sends drain FIFO after outer rejection")
    @MainActor
    func modalCancellationPolicyReentrantSendsDrainAfterOuterMutation() throws {
        let reentry = FlowParityModalCancellationPolicyReentry()
        let events = Mutex<[FlowEvent<FlowParityRoute>]>([])
        let middleware = AnyModalMiddleware<FlowParityRoute>(
            willExecute: { command, _, _ in
                guard command == .dismissAll else { return .proceed(command) }
                return .cancel(.middleware(debugName: "dismiss-gate", command: command))
            }
        )
        let store = FlowStore<FlowParityRoute>(
            initial: [.sheet(.modal)],
            configuration: .init(
                modal: .init(
                    middlewares: [.init(middleware: middleware)],
                    queueCancellationPolicy: .custom { command, reason in
                        reentry.resolve(command: command, reason: reason)
                    }
                ),
                onEvent: { event in events.withLock { $0.append(event) } }
            )
        )
        reentry.store = store
        store.send(.presentSheet(.queuedModal))
        events.withLock { $0.removeAll() }

        store.send(.dismissAll)

        #expect(store.path == [.sheet(.rewritten)])
        #expect(store.modalStore.currentPresentation?.route == .rewritten)
        #expect(store.modalStore.queuedPresentations.isEmpty)

        let captured = events.withLock { $0 }
        let rejectionIndex = try #require(captured.firstIndex { event in
            if case .intentRejected(
                .dismissAll,
                .middlewareRejected(debugName: "dismiss-gate")
            ) = event {
                return true
            }
            return false
        })
        let dismissalIndex = try #require(captured.firstIndex { event in
            if case .modal(.dismissed(let presentation, .dismiss)) = event {
                return presentation.route == .modal
            }
            return false
        })
        let presentationIndex = try #require(captured.firstIndex { event in
            if case .modal(.presented(let presentation)) = event {
                return presentation.route == .rewritten
            }
            return false
        })
        #expect(rejectionIndex < dismissalIndex)
        #expect(dismissalIndex < presentationIndex)
    }

    @Test("reset cancellation discards preceding previews and finalizes against live modal state")
    @MainActor
    func resetModalCancellationDiscardsPreviewsAndReportsLiveState() {
        let navigationMiddleware = FlowParityResetNavigationMiddleware()
        let events = Mutex<[FlowEvent<FlowParityRoute>]>([])
        let modalMiddleware = FlowParityResetModalMiddleware()
        let store = FlowStore<FlowParityRoute>(
            initial: [.push(.root), .sheet(.modal)],
            configuration: .init(
                navigation: .init(
                    middlewares: [
                        .init(middleware: AnyNavigationMiddleware(navigationMiddleware))
                    ]
                ),
                modal: .init(
                    middlewares: [
                        .init(
                            middleware: AnyModalMiddleware(modalMiddleware),
                            debugName: "reset-modal-gate"
                        )
                    ]
                ),
                onEvent: { event in events.withLock { $0.append(event) } }
            )
        )
        store.send(.presentSheet(.queuedModal))
        modalMiddleware.resetRecords()
        events.withLock { $0.removeAll() }

        store.send(.reset([.push(.first), .sheet(.rewritten)]))

        #expect(store.path == [.push(.root), .sheet(.modal)])
        #expect(store.navigationStore.state.path == [.root])
        #expect(store.modalStore.currentPresentation?.route == .modal)
        #expect(store.modalStore.queuedPresentations.map(\.route) == [.queuedModal])
        #expect(navigationMiddleware.finalized.isEmpty)
        #expect(navigationMiddleware.discarded == [.replace([.first])])
        #expect(modalMiddleware.discarded == [
            FlowParityModalLifecycleRecord(
                command: .dismissAll,
                currentRoute: nil,
                queuedRoutes: []
            )
        ])
        #expect(modalMiddleware.finalized.count == 1)
        #expect(modalMiddleware.finalized[0].currentRoute == .modal)
        #expect(modalMiddleware.finalized[0].queuedRoutes == [.queuedModal])
        #expect({
            guard case .present(let presentation) = modalMiddleware.finalized[0].command else {
                return false
            }
            return presentation.route == .rewritten
        }())
        #expect(events.withLock { captured in
            captured.contains {
                if case .modal(.commandIntercepted(.present, result: .cancelled)) = $0 {
                    return true
                }
                return false
            }
        })
        #expect(events.withLock { captured in
            captured.contains {
                if case .intentRejected(
                    .reset([.push(.first), .sheet(.rewritten)]),
                    .middlewareRejected(debugName: "reset-modal-gate")
                ) = $0 {
                    return true
                }
                return false
            }
        })
        #expect(events.withLock { captured in
            !captured.contains {
                switch $0 {
                case .pathChanged, .modal(.dismissed), .modal(.presented):
                    return true
                default:
                    return false
                }
            }
        })
    }

    @Test("reentrant parity intents drain in FIFO order after the outer mutation")
    @MainActor
    func parityIntentsPreserveReentrantOrdering() {
        let observer = FlowParityReentrantObserver()
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(onEvent: { event in observer.handle(event) })
        )
        observer.store = store

        store.send(.push(.root))

        #expect(store.path == [.push(.root), .push(.first)])
        #expect(observer.changedPaths == [
            [.push(.root)],
            [.push(.root), .push(.first), .push(.second)],
            [.push(.root), .push(.first)],
        ])
    }

    @Test("middleware reentrant sends wait for the outer preview and drain FIFO")
    @MainActor
    func middlewareReentrantSendsPreserveOuterMutationAndFIFOOrder() {
        let middleware = FlowParityReentrantNavigationMiddleware()
        let store = FlowStore<FlowParityRoute>(
            configuration: .init(
                navigation: .init(
                    middlewares: [
                        .init(middleware: AnyNavigationMiddleware(middleware))
                    ]
                )
            )
        )
        middleware.store = store

        store.send(.push(.root))

        #expect(store.path == [
            .push(.root),
            .push(.first),
            .push(.second),
        ])
        #expect(middleware.observedCommands == [
            .push(.root),
            .push(.first),
            .push(.second),
        ])
    }
}
