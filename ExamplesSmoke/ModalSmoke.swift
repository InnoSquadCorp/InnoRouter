import OSLog
import SwiftUI

import InnoRouter

enum ModalDemoRoute: Route {
    case home
}

enum ModalDemoPresentation: Route {
    case profile
    case onboarding
}

struct ModalSmokeExampleView: View {
    @State private var navigationStore = NavigationStore<ModalDemoRoute>()
    @State private var modalStore = ModalStore<ModalDemoPresentation>(
        configuration: .init(
            logger: Logger(subsystem: "com.example.innorouter", category: "modal")
        )
    )

    var body: some View {
        ModalHost(store: modalStore) { route in
            switch route {
            case .profile:
                ModalProfileView()
                    .presentationDetents([.medium])
            case .onboarding:
                ModalOnboardingView()
            }
        } content: {
            NavigationHost(store: navigationStore) { _ in
                ModalRootView()
            } root: {
                ModalRootView()
            }
        }
    }
}

struct ModalRootView: View {
    @EnvironmentRouter(ModalDemoPresentation.self) private var router

    var body: some View {
        VStack(spacing: 12) {
            Button("Show Profile") {
                router.sheet(.profile)
            }
            Button("Show Onboarding") {
                router.cover(.onboarding)
            }
        }
    }
}

struct ModalProfileView: View {
    @EnvironmentRouter(ModalDemoPresentation.self) private var router

    var body: some View {
        VStack(spacing: 12) {
            Text("Profile")
            Button("Dismiss") {
                router.dismiss()
            }
        }
        .padding()
    }
}

struct ModalOnboardingView: View {
    @EnvironmentRouter(ModalDemoPresentation.self) private var router

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Onboarding")
                Button("Dismiss") {
                    router.dismiss()
                }
            }
            .padding()
            .navigationTitle("Welcome")
        }
    }
}
