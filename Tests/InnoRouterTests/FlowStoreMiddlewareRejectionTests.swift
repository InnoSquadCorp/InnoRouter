// MARK: - FlowStoreMiddlewareRejectionTests.swift
// InnoRouterTests - FlowStore rolls back on middleware cancellations
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum FlowMiddlewareRoute: Route {
    case home
    case detail
    case secure
}

@Suite("FlowStore Middleware Rejection Tests")
struct FlowStoreMiddlewareRejectionTests {

    @Test("navigation middleware cancel rolls back path and emits middlewareRejected")
    @MainActor
    func navigationMiddlewareCancelRollsBackPath() {
        let rejections = Mutex<[(FlowIntent<FlowMiddlewareRoute>, FlowRejectionReason)]>([])
        let gate = AnyNavigationMiddleware<FlowMiddlewareRoute>(
            willExecute: { command, _ in
                if case .push(let route) = command, route == .secure {
                    return .cancel(.middleware(debugName: "nav-gate", command: command))
                }
                return .proceed(command)
            }
        )
        let config = FlowStoreConfiguration<FlowMiddlewareRoute>(
            navigation: .init(middlewares: [.init(middleware: gate, debugName: "nav-gate")]),
            onEvent: { event in
                guard case .intentRejected(let intent, let reason) = event else { return }
                rejections.withLock { $0.append((intent, reason)) }
            }
        )
        let store = FlowStore<FlowMiddlewareRoute>(configuration: config)
        store.send(.push(.home))

        store.send(.push(.secure))

        #expect(store.path == [.push(.home)])
        #expect(store.navigationStore.state.path == [.home])

        let events = rejections.withLock { $0 }
        #expect(events.count == 1)
        if let event = events.first {
            #expect(event.0 == .push(.secure))
            #expect(event.1 == .middlewareRejected(debugName: "nav-gate"))
        }
    }

    @Test("navigation middleware engine failure rejects instead of reporting success")
    @MainActor
    func navigationMiddlewareEngineFailureRejects() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let middleware = AnyNavigationMiddleware<FlowMiddlewareRoute>(
            willExecute: { command, _ in
                guard case .push = command else { return .proceed(command) }
                return .proceed(.pop)
            }
        )
        let store = FlowStore<FlowMiddlewareRoute>(
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)]),
                onEvent: { event in
                    guard case .intentRejected(_, let reason) = event else { return }
                    rejections.withLock { $0.append(reason) }
                }
            )
        )

        store.send(.push(.home))

        #expect(store.path.isEmpty)
        #expect(store.navigationStore.state.path.isEmpty)
        #expect(rejections.withLock { $0 } == [.navigationExecutionFailed])
    }

    @Test("navigation middleware partial engine failure rolls preview back atomically")
    @MainActor
    func navigationMiddlewarePartialFailureIsAtomic() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let middleware = AnyNavigationMiddleware<FlowMiddlewareRoute>(
            willExecute: { command, _ in
                guard case .push(.detail) = command else { return .proceed(command) }
                return .proceed(
                    .sequence([
                        .push(.detail),
                        .popCount(3),
                    ])
                )
            }
        )
        let store = FlowStore<FlowMiddlewareRoute>(
            initial: [.push(.home)],
            configuration: .init(
                navigation: .init(middlewares: [.init(middleware: middleware)]),
                onEvent: { event in
                    guard case .intentRejected(_, let reason) = event else { return }
                    rejections.withLock { $0.append(reason) }
                }
            )
        )

        store.send(.push(.detail))

        #expect(store.path == [.push(.home)])
        #expect(store.navigationStore.state.path == [.home])
        #expect(rejections.withLock { $0 } == [.navigationExecutionFailed])
    }

    @Test("modal middleware cancel rolls back modal tail and emits middlewareRejected")
    @MainActor
    func modalMiddlewareCancelRollsBackPath() {
        let rejections = Mutex<[(FlowIntent<FlowMiddlewareRoute>, FlowRejectionReason)]>([])
        let gate = AnyModalMiddleware<FlowMiddlewareRoute>(
            willExecute: { command, _, _ in
                if case .present = command {
                    return .cancel(.middleware(debugName: "sheet-gate", command: command))
                }
                return .proceed(command)
            }
        )
        let config = FlowStoreConfiguration<FlowMiddlewareRoute>(
            modal: .init(middlewares: [.init(middleware: gate, debugName: "sheet-gate")]),
            onEvent: { event in
                guard case .intentRejected(let intent, let reason) = event else { return }
                rejections.withLock { $0.append((intent, reason)) }
            }
        )
        let store = FlowStore<FlowMiddlewareRoute>(configuration: config)
        store.send(.push(.home))

        store.send(.presentSheet(.secure))

        #expect(store.path == [.push(.home)])
        #expect(store.modalStore.currentPresentation == nil)

        let events = rejections.withLock { $0 }
        #expect(events.count == 1)
        if let event = events.first {
            #expect(event.0 == .presentSheet(.secure))
            #expect(event.1 == .middlewareRejected(debugName: "sheet-gate"))
        }
    }

    @Test("reset with modal present cancellation leaves nav modal and callbacks untouched")
    @MainActor
    func resetPresentCancellationIsAtomic() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let navChanges = Mutex<Int>(0)
        let modalPresented = Mutex<Int>(0)
        let modalDismissed = Mutex<Int>(0)
        let modalQueueChanges = Mutex<Int>(0)
        let pathChanges = Mutex<Int>(0)

        let gate = AnyModalMiddleware<FlowMiddlewareRoute>(
            willExecute: { command, _, _ in
                if case .present = command {
                    return .cancel(.middleware(debugName: "sheet-gate", command: command))
                }
                return .proceed(command)
            }
        )

        let store = FlowStore<FlowMiddlewareRoute>(
            configuration: .init(
                navigation: .init(
                    onEvent: { event in
                        guard case .changed = event else { return }
                        navChanges.withLock { $0 += 1 }
                    }
                ),
                modal: .init(
                    middlewares: [.init(middleware: gate, debugName: "sheet-gate")],
                    onEvent: { event in
                        switch event {
                        case .presented:
                            modalPresented.withLock { $0 += 1 }
                        case .dismissed:
                            modalDismissed.withLock { $0 += 1 }
                        case .queueChanged:
                            modalQueueChanges.withLock { $0 += 1 }
                        default:
                            break
                        }
                    }
                ),
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

        store.send(.push(.home))
        navChanges.withLock { $0 = 0 }
        modalPresented.withLock { $0 = 0 }
        modalDismissed.withLock { $0 = 0 }
        modalQueueChanges.withLock { $0 = 0 }
        pathChanges.withLock { $0 = 0 }

        store.send(.reset([.push(.detail), .sheet(.secure)]))

        #expect(store.path == [.push(.home)])
        #expect(store.navigationStore.state.path == [.home])
        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(navChanges.withLock { $0 } == 0)
        #expect(modalPresented.withLock { $0 } == 0)
        #expect(modalDismissed.withLock { $0 } == 0)
        #expect(modalQueueChanges.withLock { $0 } == 0)
        #expect(pathChanges.withLock { $0 } == 0)
        #expect(rejections.withLock { $0 } == [.middlewareRejected(debugName: "sheet-gate")])
    }

    @Test("reset with dismissAll cancellation leaves existing modal state untouched")
    @MainActor
    func resetDismissAllCancellationIsAtomic() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let navChanges = Mutex<Int>(0)
        let modalPresented = Mutex<Int>(0)
        let modalDismissed = Mutex<Int>(0)
        let modalQueueChanges = Mutex<Int>(0)
        let pathChanges = Mutex<Int>(0)

        let gate = AnyModalMiddleware<FlowMiddlewareRoute>(
            willExecute: { command, _, _ in
                if case .dismissAll = command {
                    return .cancel(.middleware(debugName: "dismiss-gate", command: command))
                }
                return .proceed(command)
            }
        )

        let store = FlowStore<FlowMiddlewareRoute>(
            configuration: .init(
                navigation: .init(
                    onEvent: { event in
                        guard case .changed = event else { return }
                        navChanges.withLock { $0 += 1 }
                    }
                ),
                modal: .init(
                    middlewares: [.init(middleware: gate, debugName: "dismiss-gate")],
                    onEvent: { event in
                        switch event {
                        case .presented:
                            modalPresented.withLock { $0 += 1 }
                        case .dismissed:
                            modalDismissed.withLock { $0 += 1 }
                        case .queueChanged:
                            modalQueueChanges.withLock { $0 += 1 }
                        default:
                            break
                        }
                    }
                ),
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

        store.send(.push(.home))
        store.send(.presentSheet(.secure))
        store.send(.presentSheet(.detail))

        navChanges.withLock { $0 = 0 }
        modalPresented.withLock { $0 = 0 }
        modalDismissed.withLock { $0 = 0 }
        modalQueueChanges.withLock { $0 = 0 }
        pathChanges.withLock { $0 = 0 }

        store.send(.reset([.push(.detail)]))

        #expect(store.path == [.push(.home), .sheet(.secure)])
        #expect(store.navigationStore.state.path == [.home])
        #expect(store.modalStore.currentPresentation?.route == .secure)
        #expect(store.modalStore.queuedPresentations.map(\.route) == [.detail])
        #expect(navChanges.withLock { $0 } == 0)
        #expect(modalPresented.withLock { $0 } == 0)
        #expect(modalDismissed.withLock { $0 } == 0)
        #expect(modalQueueChanges.withLock { $0 } == 0)
        #expect(pathChanges.withLock { $0 } == 0)
        #expect(rejections.withLock { $0 } == [.middlewareRejected(debugName: "dismiss-gate")])
    }
}
