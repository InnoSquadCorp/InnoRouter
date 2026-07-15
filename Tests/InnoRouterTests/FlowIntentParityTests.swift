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

    @Test("invalid popCount and missing popTo preserve state after preview")
    @MainActor
    func invalidPopParityPreservesState() {
        let commands = Mutex<[NavigationCommand<FlowParityRoute>]>([])
        let pathChanges = Mutex<Int>(0)
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
                    guard case .pathChanged = event else { return }
                    pathChanges.withLock { $0 += 1 }
                }
            )
        )

        store.send(.popCount(0))
        store.send(.popCount(-1))
        store.send(.popCount(3))
        store.send(.popTo(.missing))

        #expect(store.path == [.push(.root), .push(.first)])
        #expect(pathChanges.withLock { $0 } == 0)
        #expect(commands.withLock { $0 } == [
            .popCount(0),
            .popCount(-1),
            .popCount(3),
            .popTo(.missing),
        ])
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
        let middleware = AnyNavigationMiddleware<FlowParityRoute>(
            willExecute: { command, _ in
                guard case .popCount = command else { return .proceed(command) }
                return .cancel(.middleware(debugName: "pop-gate", command: command))
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
}
