// MARK: - NavigationIntentTests.swift
// InnoRouter Tests
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import Observation
import OSLog
import Synchronization
import SwiftUI
import InnoRouter
import InnoRouterEffects
@testable import InnoRouterSwiftUI

// MARK: - NavigationIntent Tests

@Suite("NavigationIntent Tests")
struct NavigationIntentTests {
    @Test("NavigationStore send goMany uses batch execution for multiple routes")
    @MainActor
    func testSendGoMany() {
        var changeCount = 0
        var observedBatch: NavigationBatchResult<TestRoute>?
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    switch event {
                    case .changed:
                        changeCount += 1
                    case .batchExecuted(let batch):
                        observedBatch = batch
                    default:
                        break
                    }
                }
            )
        )

        store.send(.goMany([.home, .detail(id: "123"), .settings]))

        #expect(store.state.path == [.home, .detail(id: "123"), .settings])
        #expect(changeCount == 1)
        #expect(observedBatch?.requestedCommands == [.push(.home), .push(.detail(id: "123")), .push(.settings)])
        #expect(observedBatch?.executedCommands == [.push(.home), .push(.detail(id: "123")), .push(.settings)])
        #expect(observedBatch?.results == [.success, .success, .success])
    }

    @Test("NavigationStore send backBy pops expected count")
    @MainActor
    func testSendBackBy() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )

        store.send(.backBy(2))

        #expect(store.state.path == [.home])
    }

    @Test("NavigationStore send backBy zero routes through popCount semantics")
    @MainActor
    func testSendBackByZeroUsesPopCount() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home])
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.backBy(0))

        #expect(seenCommands == [.popCount(0)])
        #expect(store.state.path == [.home])
    }

    @Test("NavigationStore send backBy zero on empty stack still routes through popCount semantics")
    @MainActor
    func testSendBackByZeroOnEmptyUsesPopCount() {
        let store = NavigationStore<TestRoute>()
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.backBy(0))

        #expect(seenCommands == [.popCount(0)])
        #expect(store.state.path.isEmpty)
    }

    @Test("NavigationStore send backTo pops to matching route")
    @MainActor
    func testSendBackTo() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )

        store.send(.backTo(.detail(id: "123")))

        #expect(store.state.path == [.home, .detail(id: "123")])
    }

    @Test("NavigationStore send backToRoot clears stack")
    @MainActor
    func testSendBackToRoot() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )

        store.send(.backToRoot)

        #expect(store.state.path.isEmpty)
    }

    @Test("NavigationStore send replaceStack overwrites path via replace command")
    @MainActor
    func testSendReplaceStack() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .detail(id: "123")])
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.replaceStack([.settings]))

        #expect(seenCommands == [.replace([.settings])])
        #expect(store.state.path == [.settings])
    }

    @Test("NavigationStore send backOrPush pops to existing route")
    @MainActor
    func testSendBackOrPushWhenRouteExists() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.backOrPush(.detail(id: "123")))

        #expect(seenCommands == [.popTo(.detail(id: "123"))])
        #expect(store.state.path == [.home, .detail(id: "123")])
    }

    @Test("NavigationStore send backOrPush pushes when route is absent")
    @MainActor
    func testSendBackOrPushWhenRouteMissing() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home])
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.backOrPush(.settings))

        #expect(seenCommands == [.push(.settings)])
        #expect(store.state.path == [.home, .settings])
    }

    @Test("NavigationStore send pushUniqueRoot pushes when absent")
    @MainActor
    func testSendPushUniqueRootWhenAbsent() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home])
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.pushUniqueRoot(.settings))

        #expect(seenCommands == [.push(.settings)])
        #expect(store.state.path == [.home, .settings])
    }

    @Test("NavigationStore send pushUniqueRoot is a no-op when present")
    @MainActor
    func testSendPushUniqueRootWhenPresent() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.send(.pushUniqueRoot(.detail(id: "123")))

        #expect(seenCommands.isEmpty)
        #expect(store.state.path == [.home, .detail(id: "123"), .settings])
    }
}
