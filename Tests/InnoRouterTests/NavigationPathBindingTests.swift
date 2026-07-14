// MARK: - NavigationPathBindingTests.swift
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

// MARK: - NavigationPathBinding Tests

@Suite("NavigationPathBinding Tests")
struct NavigationPathBindingTests {
    @Test("Path binding shrink uses popCount")
    @MainActor
    func testPathBindingShrinkUsesPopCount() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = [.home, .detail(id: "123")]

        #expect(executedCommands == [.popCount(1)])
        #expect(store.state.path == [.home, .detail(id: "123")])
    }

    @Test("Path binding root shrink uses popToRoot")
    @MainActor
    func testPathBindingRootShrinkUsesPopToRoot() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings]
        )
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = []

        #expect(executedCommands == [.popToRoot])
        #expect(store.state.path.isEmpty)
    }

    @Test("Path binding expansion uses batch push execution")
    @MainActor
    func testPathBindingExpansionUsesBatchPushes() throws {
        var changeCount = 0
        var observedBatch: NavigationBatchResult<TestRoute>?
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home],
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
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = [.home, .detail(id: "123"), .settings]

        #expect(executedCommands == [.push(.detail(id: "123")), .push(.settings)])
        #expect(store.state.path == [.home, .detail(id: "123"), .settings])
        #expect(changeCount == 1)
        #expect(observedBatch?.requestedCommands == [.push(.detail(id: "123")), .push(.settings)])
        #expect(observedBatch?.executedCommands == [.push(.detail(id: "123")), .push(.settings)])
        #expect(observedBatch?.results == [.success, .success])
    }

    @Test("Path binding non-prefix rewrite falls back to replace")
    @MainActor
    func testPathBindingNonPrefixRewriteUsesReplace() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123")]
        )
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = [.home, .settings]

        #expect(executedCommands == [.replace([.home, .settings])])
        #expect(store.state.path == [.home, .settings])
    }

    @Test("Path binding non-prefix rewrite can ignore changes")
    @MainActor
    func testPathBindingNonPrefixRewriteIgnore() throws {
        var changeCount = 0
        var batchCount = 0
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123")],
            configuration: NavigationStoreConfiguration(
                pathMismatchPolicy: .ignore,
                onEvent: { event in
                    switch event {
                    case .changed:
                        changeCount += 1
                    case .batchExecuted:
                        batchCount += 1
                    default:
                        break
                    }
                }
            )
        )
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = [.home, .settings]

        #expect(executedCommands.isEmpty)
        #expect(changeCount == 0)
        #expect(batchCount == 0)
        #expect(store.state.path == [.home, .detail(id: "123")])
    }

    @Test("Path binding non-prefix rewrite custom single resolution runs execute")
    @MainActor
    func testPathBindingNonPrefixRewriteCustomSingle() throws {
        let store = NavigationStore<TestRoute>(
            initial: try validatedStack([.home, .detail(id: "123")]),
            configuration: NavigationStoreConfiguration(
                pathMismatchPolicy: .custom { _, _ in
                    .single(.popToRoot)
                }
            )
        )
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = [.home, .settings]

        #expect(executedCommands == [.popToRoot])
        #expect(store.state.path.isEmpty)
    }

    @Test("Path binding non-prefix rewrite custom batch resolution runs executeBatch")
    @MainActor
    func testPathBindingNonPrefixRewriteCustomBatch() throws {
        var changeCount = 0
        var observedBatch: NavigationBatchResult<TestRoute>?
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home],
            configuration: NavigationStoreConfiguration(
                pathMismatchPolicy: .custom { _, _ in
                    .batch([.push(.settings), .push(.detail(id: "123"))])
                },
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
        var executedCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    executedCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.pathBinding.wrappedValue = [.settings]

        #expect(executedCommands == [.push(.settings), .push(.detail(id: "123"))])
        #expect(changeCount == 1)
        #expect(observedBatch?.requestedCommands == [.push(.settings), .push(.detail(id: "123"))])
        #expect(store.state.path == [.home, .settings, .detail(id: "123")])
    }

    @Test("Path binding non-prefix rewrite assert-and-replace reports and falls back")
    @MainActor
    func testPathBindingNonPrefixRewriteAssertAndReplace() throws {
        var assertionCount = 0
        let store = NavigationStore<TestRoute>(
            initial: try validatedStack([.home, .detail(id: "123")]),
            configuration: NavigationStoreConfiguration(
                pathMismatchPolicy: .assertAndReplace
            ),
            nonPrefixAssertionHandler: { _, _ in
                assertionCount += 1
            }
        )

        store.pathBinding.wrappedValue = [.home, .settings]

        #expect(assertionCount == 1)
        #expect(store.state.path == [.home, .settings])
    }
}
