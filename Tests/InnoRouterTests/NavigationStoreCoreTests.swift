// MARK: - NavigationStoreCoreTests.swift
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

// MARK: - NavigationStore Tests

@Suite("NavigationStore Tests")
struct NavigationStoreTests {
    @Test("Configuration init observes changed and batch events")
    @MainActor
    func testConfigurationInitParity() throws {
        var changeCount = 0
        var batchCount = 0
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home],
            configuration: NavigationStoreConfiguration(
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

        _ = store.execute(.push(.settings))
        _ = store.executeBatch([.push(.detail(id: "123")), .pop])

        #expect(store.state.path == [.home, .settings])
        #expect(changeCount == 1)
        #expect(batchCount == 1)
    }

    @Test("Configuration initialPath validates before store creation")
    @MainActor
    func testConfigurationInitialPathValidation() {
        do {
            _ = try NavigationStore<TestRoute>(
                initialPath: [.settings],
                configuration: NavigationStoreConfiguration(
                    routeStackValidator: .rooted(at: .home)
                )
            )
            Issue.record("Expected validator to reject initial path")
        } catch let error as RouteStackValidationError<TestRoute> {
            #expect(error == .invalidRoot(expected: .home, actual: .settings))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Push adds route to path")
    @MainActor
    func testPush() {
        let store = NavigationStore<TestRoute>()

        _ = store.execute(.push(.home))
        #expect(store.state.path.count == 1)
        #expect(store.state.path.last == .home)

        _ = store.execute(.push(.detail(id: "123")))
        #expect(store.state.path.count == 2)
        #expect(store.state.path.last == .detail(id: "123"))
    }

    @Test("Pop removes last route")
    @MainActor
    func testPop() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .detail(id: "123")])

        let result = store.execute(.pop)
        #expect(result == .success)
        #expect(store.state.path.count == 1)
        #expect(store.state.path.last == .home)
    }

    @Test("Pop on empty returns emptyStack")
    @MainActor
    func testPopEmpty() {
        let store = NavigationStore<TestRoute>()

        let result = store.execute(.pop)
        #expect(result == .emptyStack)
        #expect(store.state.path.isEmpty)
    }

    @Test("PopToRoot clears all routes")
    @MainActor
    func testPopToRoot() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .detail(id: "123"), .settings])

        let result = store.execute(.popToRoot)
        #expect(result == .success)
        #expect(store.state.path.isEmpty)
    }

    @Test("PopToRoot on an empty stack succeeds as an idempotent no-op")
    @MainActor
    func testPopToRootEmpty() {
        let store = NavigationStore<TestRoute>()

        let result = store.execute(.popToRoot)
        #expect(result == .success)
        #expect(store.state.path.isEmpty)
    }

    @Test("Replace replaces entire stack")
    @MainActor
    func testReplace() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .detail(id: "123")])

        let result = store.execute(.replace([.settings]))
        #expect(result == .success)
        #expect(store.state.path.count == 1)
        #expect(store.state.path.last == .settings)
    }

    @Test("Pop to specific route")
    @MainActor
    func testPopTo() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .detail(id: "123"), .settings])

        let result = store.execute(.popTo(.detail(id: "123")))
        #expect(result == .success)
        #expect(store.state.path.count == 2)
        #expect(store.state.path.last == .detail(id: "123"))
    }

    @Test("Pop to nearest matching route when duplicates exist")
    @MainActor
    func testPopToNearestMatch() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "123"), .settings, .detail(id: "123"), .profile(userId: "u1", tab: 0)]
        )

        let result = store.execute(.popTo(.detail(id: "123")))

        #expect(result == .success)
        #expect(store.state.path == [.home, .detail(id: "123"), .settings, .detail(id: "123")])
    }

    @Test("onEvent receives changed events")
    @MainActor
    func testChangedEventObservation() {
        var changeCount = 0
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    guard case .changed = event else { return }
                    changeCount += 1
                }
            )
        )

        _ = store.execute(.push(.home))
        _ = store.execute(.push(.detail(id: "123")))
        _ = store.execute(.pop)

        #expect(changeCount == 3)
    }
}
