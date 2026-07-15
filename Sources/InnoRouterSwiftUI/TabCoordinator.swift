import Observation
import SwiftUI

import InnoRouterCore

/// A route that can be rendered as a native tab item.
///
/// `@Router` generates this conformance when every route case carries
/// `@TabItem` metadata. Manual conformances remain available for advanced
/// `TabCoordinator` shells. The default `id` implementation makes every tab
/// its own identity so `TabView(selection:)` can use the route directly.
public protocol RouterTab: Route, CaseIterable, Identifiable {
    /// Human-readable label rendered alongside the icon.
    var title: String { get }
    /// SF Symbol name rendered in the tab's `Label`.
    var systemImage: String { get }
}

public extension RouterTab {
    var id: Self { self }
}

/// A presentation-layer protocol for tab-based navigation surfaces.
///
/// `TabCoordinator` owns the currently-selected tab and a per-tab
/// badge dictionary. It complements rather than replaces
/// `NavigationStore` / `ModalStore`: each tab usually owns its own
/// per-tab navigation stack, while the coordinator only tracks which
/// tab is in front and any unread-count overlays.
///
/// ## Platform availability
///
/// `TabCoordinatorView` renders through `TabView`, which is available on every
/// InnoRouter platform. On tvOS and watchOS badge state is preserved while the
/// unavailable native visual is omitted. The first positive badge passed to
/// ``TabCoordinator/setBadge(_:for:)`` reports one privacy-safe runtime warning.
///
/// ## Conforming
///
/// Conformers are reference types because they carry mutable
/// `selectedTab` / `tabBadges` state observed by SwiftUI. They are
/// `@MainActor`-isolated so SwiftUI binding writes stay on the main
/// thread.
///
/// ```swift
/// @Observable @MainActor
/// final class AppTabs: TabCoordinator {
///     enum TabType: String, RouterTab { case home, search, profile
///         var title: String { rawValue.capitalized }
///         var systemImage: String { rawValue + ".fill" }
///     }
///     var selectedTab: TabType = .home
///     var tabBadges: [TabType: Int] = [:]
///     @ViewBuilder
///     func content(for tab: TabType) -> some View { … }
/// }
/// ```
@MainActor
public protocol TabCoordinator: AnyObject, Observable {
    associatedtype TabType: RouterTab
    associatedtype TabContent: View

    var selectedTab: TabType { get set }
    var tabBadges: [TabType: Int] { get set }

    @ViewBuilder
    func content(for tab: TabType) -> TabContent
}

public extension TabCoordinator {
    func switchTab(to tab: TabType) {
        selectedTab = tab
    }

    func setBadge(_ count: Int, for tab: TabType) {
        UnsupportedTabBadgeDiagnostics.reportIfNeeded(count)
        tabBadges[tab] = count > 0 ? count : nil
    }

    func badge(for tab: TabType) -> Int? {
        tabBadges[tab]
    }

    func clearAllBadges() {
        tabBadges.removeAll()
    }
}

public struct TabCoordinatorView<C: TabCoordinator>: View {
    @Bindable private var coordinator: C

    public init(coordinator: C) {
        self.coordinator = coordinator
    }

    public var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            ForEach(Array(C.TabType.allCases), id: \.self) { tab in
                coordinator.content(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
                    .routerTabBadge(coordinator.tabBadges[tab])
            }
        }
    }
}
