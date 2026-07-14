// MARK: - ModalStoreInterceptionTests.swift
// InnoRouterTests - ModalStore middleware interception outcomes
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

// MARK: - Local fixtures

private enum InterceptRoute: Route {
    case login
    case profile
}

@Suite("ModalStore Interception Tests")
struct ModalStoreInterceptionTests {

    @Test("willExecute cancel on .present leaves state unchanged and emits cancelled intercept")
    @MainActor
    func cancelPresentLeavesStateUnchanged() {
        let presented = Mutex<Int>(0)
        let intercepted = Mutex<[(ModalCommand<InterceptRoute>, ModalExecutionResult<InterceptRoute>)]>([])
        let middleware = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in
                .cancel(.middleware(debugName: "gate", command: command))
            }
        )

        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                middlewares: [.init(middleware: middleware, debugName: "gate")],
                onEvent: { event in
                    switch event {
                    case .presented:
                        presented.withLock { $0 += 1 }
                    case .commandIntercepted(let command, let result):
                        intercepted.withLock { $0.append((command, result)) }
                    default:
                        break
                    }
                }
            )
        )

        store.present(.login, style: .sheet)

        #expect(store.currentPresentation == nil)
        #expect(presented.withLock { $0 } == 0)
        let events = intercepted.withLock { $0 }
        #expect(events.count == 1)
        guard let event = events.first else { return }
        if case .cancelled(let reason) = event.1,
           case .middleware(let debugName, _) = reason {
            #expect(debugName == "gate")
        } else {
            Issue.record("Expected cancelled result with middleware reason, got: \(event.1)")
        }
    }

    @Test("middleware can rewrite .present sheet into a fullScreenCover")
    @MainActor
    func middlewareCanRewritePresentStyle() {
        let middleware = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in
                if case .present(let presentation) = command, presentation.style == .sheet {
                    let rewritten = ModalPresentation(
                        id: presentation.id,
                        route: presentation.route,
                        style: .fullScreenCover
                    )
                    return .proceed(.present(rewritten))
                }
                return .proceed(command)
            }
        )

        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                middlewares: [.init(middleware: middleware)]
            )
        )

        store.present(.login, style: .sheet)

        #expect(store.currentPresentation?.style == .fullScreenCover)
        #expect(store.currentPresentation?.route == .login)
    }

    @Test("cancel on .dismissCurrent preserves current presentation")
    @MainActor
    func cancelDismissCurrentPreservesState() {
        let cancelGate = Mutex<Bool>(false)
        let middleware = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in
                if case .dismissCurrent = command, cancelGate.withLock({ $0 }) {
                    return .cancel(.middleware(debugName: "no-dismiss", command: command))
                }
                return .proceed(command)
            }
        )
        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                middlewares: [.init(middleware: middleware, debugName: "no-dismiss")]
            )
        )
        store.present(.profile, style: .sheet)
        cancelGate.withLock { $0 = true }
        store.dismissCurrent()

        #expect(store.currentPresentation?.route == .profile)
    }

    @Test("cancel on .dismissAll preserves current + queue")
    @MainActor
    func cancelDismissAllPreservesState() {
        let cancelGate = Mutex<Bool>(false)
        let middleware = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in
                if case .dismissAll = command, cancelGate.withLock({ $0 }) {
                    return .cancel(.middleware(debugName: "no-dismiss-all", command: command))
                }
                return .proceed(command)
            }
        )
        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                middlewares: [.init(middleware: middleware, debugName: "no-dismiss-all")]
            )
        )
        store.present(.profile, style: .sheet)
        store.present(.login, style: .sheet)
        #expect(store.queuedPresentations.count == 1)
        cancelGate.withLock { $0 = true }
        store.dismissAll()

        #expect(store.currentPresentation?.route == .profile)
        #expect(store.queuedPresentations.count == 1)
    }

    @Test("cancel on .replaceCurrent preserves current presentation")
    @MainActor
    func cancelReplaceCurrentPreservesState() {
        let cancelGate = Mutex<Bool>(false)
        let middleware = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in
                if case .replaceCurrent = command, cancelGate.withLock({ $0 }) {
                    return .cancel(.middleware(debugName: "no-replace", command: command))
                }
                return .proceed(command)
            }
        )
        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                middlewares: [.init(middleware: middleware, debugName: "no-replace")]
            )
        )
        store.present(.login, style: .sheet)
        let originalID = store.currentPresentation?.id
        cancelGate.withLock { $0 = true }

        store.replaceCurrent(.profile, style: .sheet)

        #expect(store.currentPresentation?.route == .login)
        #expect(store.currentPresentation?.id == originalID)
    }

    @Test("participant discipline: didExecute only runs for middlewares that proceeded")
    @MainActor
    func participantDiscipline() {
        let firstDidExecute = Mutex<Int>(0)
        let secondDidExecute = Mutex<Int>(0)
        let thirdDidExecute = Mutex<Int>(0)

        let first = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in .proceed(command) },
            didExecute: { _, _, _ in firstDidExecute.withLock { $0 += 1 } }
        )
        let second = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in
                .cancel(.middleware(debugName: "blocker", command: command))
            },
            didExecute: { _, _, _ in secondDidExecute.withLock { $0 += 1 } }
        )
        let third = AnyModalMiddleware<InterceptRoute>(
            willExecute: { command, _, _ in .proceed(command) },
            didExecute: { _, _, _ in thirdDidExecute.withLock { $0 += 1 } }
        )

        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                middlewares: [
                    .init(middleware: first),
                    .init(middleware: second, debugName: "blocker"),
                    .init(middleware: third)
                ]
            )
        )

        store.present(.login, style: .sheet)

        // Matches NavigationMiddleware participant discipline: didExecute
        // runs on the prefix of middlewares that observed willExecute
        // (including the blocker), but not on middlewares that never saw
        // the command.
        #expect(firstDidExecute.withLock { $0 } == 1)
        #expect(secondDidExecute.withLock { $0 } == 1)
        #expect(thirdDidExecute.withLock { $0 } == 0)
    }

    @Test("executed outcome surfaces via onEvent")
    @MainActor
    func executedOutcomeSurfaces() {
        let intercepted = Mutex<[(ModalCommand<InterceptRoute>, ModalExecutionResult<InterceptRoute>)]>([])
        let store = ModalStore<InterceptRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .commandIntercepted(let command, let result) = event else { return }
                    intercepted.withLock { $0.append((command, result)) }
                }
            )
        )

        store.present(.login, style: .sheet)
        store.replaceCurrent(.profile, style: .sheet)
        store.present(.profile, style: .sheet)
        store.dismissCurrent()
        store.dismissAll()

        let results = intercepted.withLock { $0 }
        #expect(results.count == 5)

        if case .executed = results[0].1 {} else { Issue.record("expected executed for first present, got \(results[0].1)") }
        if case .replaceCurrent(let presentation) = results[1].0 {
            #expect(presentation.route == .profile)
            #expect(presentation.style == .sheet)
        } else {
            Issue.record("expected replaceCurrent command second, got \(results[1].0)")
        }
        if case .executed = results[1].1 {} else { Issue.record("expected executed for replaceCurrent, got \(results[1].1)") }
        if case .queued = results[2].1 {} else { Issue.record("expected queued for second present, got \(results[2].1)") }
        if case .executed = results[3].1 {} else { Issue.record("expected executed for dismissCurrent, got \(results[3].1)") }
        if case .executed = results[4].1 {} else { Issue.record("expected executed for dismissAll, got \(results[4].1)") }
    }
}
