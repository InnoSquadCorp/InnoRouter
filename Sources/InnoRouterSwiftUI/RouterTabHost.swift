import Observation
import OSLog
import SwiftUI

import InnoRouterCore

@MainActor
enum UnsupportedTabBadgeDiagnostics {
    private static let logger = Logger(
        subsystem: "com.innosquad.InnoRouter",
        category: "tab-presentation"
    )
    private static var hasReported = false

    static func reportIfNeeded(_ count: Int?) {
#if os(tvOS) || os(watchOS)
        guard let count, count > 0, !hasReported else { return }
        hasReported = true
        logger.warning(
            "Tab badge state is retained, but the native badge visual is unavailable on this platform."
        )
#else
        _ = count
#endif
    }
}

@MainActor
@Observable
final class RouterTabState<R: RouterTab> {
    var selection: R
    private(set) var badges: [R: Int]

    @ObservationIgnored
    private var cachedActionHandler: RouterTabActionHandler<R>?

    init(
        initial: R,
        badges: [R: Int] = [:]
    ) {
        self.selection = initial
        self.badges = badges.filter { $0.value > 0 }
        UnsupportedTabBadgeDiagnostics.reportIfNeeded(self.badges.values.first)
    }

    var actionHandler: RouterTabActionHandler<R> {
        if let cachedActionHandler {
            return cachedActionHandler
        }
        let handler: RouterTabActionHandler<R> = { [weak self] action in
            self?.send(action)
        }
        cachedActionHandler = handler
        return handler
    }

    func send(_ action: RouterTabAction<R>) {
        switch action {
        case .select(let tab):
            selection = tab
        case .setBadge(let count, let tab):
            setBadge(count, for: tab)
        case .clearAllBadges:
            badges.removeAll()
        }
    }

    func setBadge(_ count: Int?, for tab: R) {
        UnsupportedTabBadgeDiagnostics.reportIfNeeded(count)
        if let count, count > 0 {
            badges[tab] = count
        } else {
            badges[tab] = nil
        }
    }
}

extension View {
    /// Renders a native tab badge where SwiftUI supports it while keeping the
    /// same state contract on tvOS and watchOS.
    @MainActor
    @ViewBuilder
    func routerTabBadge(_ count: Int?) -> some View {
#if os(tvOS) || os(watchOS)
        self.onAppear {
            UnsupportedTabBadgeDiagnostics.reportIfNeeded(count)
        }
#else
        if let count, count > 0 {
            self.badge(count)
        } else {
            self
        }
#endif
    }
}

/// A macro-first native tab host with locally owned selection and badge state.
///
/// Annotate every case of an `@Router` enum with `@TabItem`, then pass the
/// generated route type and initial selection. Descendants switch tabs or
/// update badges through ``EnvironmentRouter`` without receiving a coordinator
/// or binding. When the route also has `@DeepLink` mappings, an admitted URL
/// automatically selects the resolved tab. Multi-window scene selection stays
/// at the SwiftUI Scene boundary.
///
/// ```swift
/// RouterTabHost(AppTab.self, initial: .home)
/// ```
///
/// Use ``TabCoordinatorView`` when the application needs to own selection,
/// provide a custom shell, or compose independently owned per-tab stores.
@MainActor
public struct RouterTabHost<R: DestinationRoute & RouterTab>: View {
    @State private var state: RouterTabState<R>

    /// Creates a native tab host with locally owned state.
    ///
    /// Non-positive initial badge counts are normalized away. On tvOS and
    /// watchOS badge state remains available to router actions, but SwiftUI's
    /// unavailable native badge visual is omitted.
    public init(
        _ routeType: R.Type,
        initial: R,
        badges: [R: Int] = [:]
    ) {
        _ = routeType
        self._state = State(
            initialValue: RouterTabState(
                initial: initial,
                badges: badges
            )
        )
    }

    init(state: RouterTabState<R>) {
        self._state = State(initialValue: state)
    }

    public var body: some View {
        @Bindable var state = state
        let tabState = state

        TabView(selection: $state.selection) {
            ForEach(Array(R.allCases), id: \.self) { tab in
                R.destination(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
                    .routerTabBadge(state.badges[tab])
            }
        }
        .routerAuthority(
            for: R.self,
            tab: state.actionHandler
        )
        .handleRouterDeepLinks(for: R.self) { route in
            tabState.send(.select(route))
        }
    }
}
