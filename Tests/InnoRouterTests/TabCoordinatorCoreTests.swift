// MARK: - TabCoordinatorCoreTests.swift
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

// MARK: - TabCoordinator Tests

@Suite("TabCoordinator Tests")
struct TabCoordinatorTests {
    enum TestTab: String, InnoRouterSwiftUI.RouterTab, CaseIterable {
        case home
        case inbox
        case settings

        var systemImage: String {
            switch self {
            case .home: "house"
            case .inbox: "tray"
            case .settings: "gearshape"
            }
        }

        var title: String {
            rawValue.capitalized
        }
    }

    @Observable
    @MainActor
    final class TestTabCoordinator: InnoRouterSwiftUI.TabCoordinator {
        typealias TabType = TestTab
        typealias TabContent = Text

        var selectedTab: TestTab = .home
        var tabBadges: [TestTab: Int] = [:]

        func content(for tab: TestTab) -> Text {
            Text(tab.title)
        }
    }

    @Test("TabCoordinator switches selected tab")
    @MainActor
    func testSwitchTab() {
        let coordinator = TestTabCoordinator()

        coordinator.switchTab(to: TestTab.inbox)

        #expect(coordinator.selectedTab == TestTab.inbox)
    }

    @Test("TabCoordinator manages badges per tab")
    @MainActor
    func testTabBadges() {
        let coordinator = TestTabCoordinator()

        coordinator.setBadge(3, for: TestTab.inbox)
        coordinator.setBadge(1, for: TestTab.settings)

        #expect(coordinator.badge(for: TestTab.inbox) == 3)
        #expect(coordinator.badge(for: TestTab.settings) == 1)
    }

    @Test("TabCoordinator clears badge state")
    @MainActor
    func testClearAllBadges() {
        let coordinator = TestTabCoordinator()
        coordinator.setBadge(2, for: TestTab.inbox)
        coordinator.setBadge(1, for: TestTab.settings)

        coordinator.clearAllBadges()

        #expect(coordinator.tabBadges.isEmpty)
        #expect(coordinator.badge(for: TestTab.inbox) == nil)
        #expect(coordinator.badge(for: TestTab.settings) == nil)
    }
}
