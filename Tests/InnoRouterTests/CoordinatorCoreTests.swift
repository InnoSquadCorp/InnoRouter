// MARK: - CoordinatorCoreTests.swift
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

// MARK: - Coordinator Tests

@Suite("Coordinator Tests", .tags(.unit))
struct CoordinatorTests {

    @Observable
    @MainActor
    final class TestCoordinator: Coordinator {
        typealias RouteType = TestRoute
        typealias Destination = EmptyView

        let store: NavigationStore<TestRoute> = NavigationStore()
        var handleCount: Int = 0

        func handle(_ intent: NavigationIntent<TestRoute>) {
            handleCount += 1
            switch intent {
            case .go(let route):
                _ = store.execute(.push(route))
            default:
                break
            }
        }

        @ViewBuilder
        func destination(for route: TestRoute) -> EmptyView {
            EmptyView()
        }
    }

    @Observable
    @MainActor
    final class DefaultBehaviorCoordinator: Coordinator {
        typealias RouteType = TestRoute
        typealias Destination = EmptyView

        let store: NavigationStore<TestRoute> = NavigationStore()

        @ViewBuilder
        func destination(for route: TestRoute) -> EmptyView {
            EmptyView()
        }
    }

    @Test("Coordinator routes via send intent")
    @MainActor
    func testNavigate() {
        let coordinator = TestCoordinator()

        coordinator.send(.go(.home))
        coordinator.send(.go(.detail(id: "123")))

        #expect(coordinator.handleCount == 2)
        #expect(coordinator.store.state.path.count == 2)
    }

    @Test("Coordinator send back pops")
    @MainActor
    func testGoBack() {
        let coordinator = DefaultBehaviorCoordinator()
        _ = coordinator.store.execute(.push(.home))
        _ = coordinator.store.execute(.push(.detail(id: "123")))

        coordinator.send(.back)

        #expect(coordinator.store.state.path.last == .home)
    }

    @Test("Coordinator send backToRoot clears stack")
    @MainActor
    func testGoToRoot() {
        let coordinator = DefaultBehaviorCoordinator()
        _ = coordinator.store.execute(.push(.home))
        _ = coordinator.store.execute(.push(.detail(id: "123")))

        coordinator.send(.backToRoot)

        #expect(coordinator.store.state.path.isEmpty)
    }

    @Test("Coordinator dispatcher sends intent to handle")
    @MainActor
    func testNavigationIntentDispatcher() {
        let coordinator = TestCoordinator()

        coordinator.navigationIntentDispatcher(.go(.home))

        #expect(coordinator.handleCount == 1)
        #expect(coordinator.store.state.path == [.home])
    }

    @Test("Default coordinator supports goMany/backBy/backTo/backToRoot")
    @MainActor
    func testDefaultCoordinatorIntentSet() {
        let coordinator = DefaultBehaviorCoordinator()

        coordinator.send(.goMany([.home, .detail(id: "123"), .settings]))
        #expect(coordinator.store.state.path == [.home, .detail(id: "123"), .settings])

        coordinator.send(.backBy(1))
        #expect(coordinator.store.state.path == [.home, .detail(id: "123")])

        coordinator.send(.backTo(.home))
        #expect(coordinator.store.state.path == [.home])

        coordinator.send(.backToRoot)
        #expect(coordinator.store.state.path.isEmpty)
    }

    // MARK: - Platform: CoordinatorSplitHost is unavailable on watchOS
    // because SwiftUI's NavigationSplitView is unavailable there. The
    // construction smoke test is gated to match.
    #if !os(watchOS)
    @Test("CoordinatorSplitHost body can be constructed")
    @MainActor
    func testCoordinatorSplitHostConstruction() {
        let coordinator = DefaultBehaviorCoordinator()
        let host = CoordinatorSplitHost(coordinator: coordinator) {
            Text("Sidebar")
        } root: {
            Text("Root")
        }

        _ = host.body
        coordinator.send(.go(.settings))

        #expect(coordinator.store.state.path == [.settings])
    }
    #endif
}
