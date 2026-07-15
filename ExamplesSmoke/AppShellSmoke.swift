import SwiftUI

import InnoRouter

enum HomeShellRoute: Route {
    case dashboard
    case checkoutFlow
}

enum SettingsShellRoute: Route {
    case list
    case detail
}

enum AppShellModalRoute: Route {
    case profile
    case onboarding
}

enum AppShellTab: String, InnoRouter.RouterTab {
    case home
    case settings

    var systemImage: String {
        switch self {
        case .home: "house"
        case .settings: "gearshape"
        }
    }

    var title: String {
        rawValue.capitalized
    }
}

enum CheckoutStep: CaseIterable, Hashable, Sendable {
    case cart
    case shipping
    case review
}

@Observable
@MainActor
final class CheckoutStepCoordinator: StepCoordinator {
    typealias Step = CheckoutStep

    var currentStep: CheckoutStep = .cart
    var completedSteps: Set<CheckoutStep> = []
}

@Observable
@MainActor
final class AppShellCoordinator: TabCoordinator {
    typealias TabType = AppShellTab
    typealias TabContent = AnyView

    var selectedTab: AppShellTab = .home
    var tabBadges: [AppShellTab: Int] = [.settings: 2]

    let homeStore = NavigationStore<HomeShellRoute>()
    let settingsStore = NavigationStore<SettingsShellRoute>()
    let modalStore = ModalStore<AppShellModalRoute>()
    let checkoutFlow = CheckoutStepCoordinator()

    func content(for tab: AppShellTab) -> AnyView {
        switch tab {
        case .home:
            return AnyView(AppShellHomeScene(coordinator: self))
        case .settings:
            return AnyView(
                NavigationHost(store: settingsStore) { route in
                    switch route {
                    case .list:
                        SettingsRootView()
                    case .detail:
                        Text("Settings Detail")
                    }
                } root: {
                    SettingsRootView()
                }
            )
        }
    }
}

struct AppShellExampleView: View {
    @State private var coordinator = AppShellCoordinator()

    var body: some View {
        TabCoordinatorView(coordinator: coordinator)
    }
}

struct AppShellHomeScene: View {
    @Bindable var coordinator: AppShellCoordinator

    var body: some View {
        ModalHost(store: coordinator.modalStore) { route in
            switch route {
            case .profile:
                AppShellProfileModalView()
                    .presentationDetents([.medium])
            case .onboarding:
                AppShellOnboardingModalView()
            }
        } content: {
            NavigationHost(store: coordinator.homeStore) { route in
                switch route {
                case .dashboard:
                    HomeDashboardView()
                case .checkoutFlow:
                    StepCoordinatorView(coordinator: coordinator.checkoutFlow) { step in
                        Text("Checkout step: \((CheckoutStep.allCases.firstIndex(of: step) ?? 0) + 1)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } root: {
                HomeDashboardView()
            }
        }
    }
}

struct HomeDashboardView: View {
    @EnvironmentNavigationIntent(HomeShellRoute.self) private var navigationIntent
    @EnvironmentModalIntent(AppShellModalRoute.self) private var modalIntent

    var body: some View {
        VStack(spacing: 12) {
            Button("Start Checkout Flow") {
                navigationIntent(.go(.checkoutFlow))
            }
            Button("Show Profile Sheet") {
                modalIntent(.present(.profile, style: .sheet))
            }
            Button("Show Onboarding Full Screen") {
                modalIntent(.present(.onboarding, style: .fullScreenCover))
            }
        }
        .navigationTitle("Home")
    }
}

struct SettingsRootView: View {
    @EnvironmentNavigationIntent(SettingsShellRoute.self) private var navigationIntent

    var body: some View {
        VStack(spacing: 12) {
            Button("Open Settings Detail") {
                navigationIntent(.go(.detail))
            }
        }
        .navigationTitle("Settings")
    }
}

struct AppShellProfileModalView: View {
    @EnvironmentModalIntent(AppShellModalRoute.self) private var modalIntent

    var body: some View {
        VStack(spacing: 12) {
            Text("Profile Modal")
            Button("Dismiss") {
                modalIntent(.dismiss)
            }
        }
        .padding()
    }
}

struct AppShellOnboardingModalView: View {
    @EnvironmentModalIntent(AppShellModalRoute.self) private var modalIntent

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Onboarding Full Screen")
                Button("Dismiss") {
                    modalIntent(.dismiss)
                }
            }
            .padding()
            .navigationTitle("Welcome")
        }
    }
}
