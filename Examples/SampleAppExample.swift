// MARK: - SampleAppExample.swift
// InnoRouter - integrated sample exercising multi-feature surface
// Copyright © 2026 Inno Squad. All rights reserved.
//
// This example combines the headline feature surface — deep-link
// pipeline with auth gating, FlowStore push+modal projection, and
// DebouncingNavigator search debouncing — into one file so adopters
// can see how the pieces compose without flipping between the
// standalone examples.
//
// It is a single-file SwiftUI scene composition rather than a full
// Xcode project. Other examples (`AppShellExample`,
// `DeepLinkExample`, `SplitCoordinatorExample`) cover host wiring
// in isolation; this file's job is to show the feature surfaces
// composed together.

import Foundation
import OSLog
import SwiftUI
import Synchronization

import InnoRouter
import InnoRouterDeepLink
import InnoRouterEffects
import InnoRouterMacros

// MARK: - Routes

@Routable
enum SampleRoute {
    case home
    case detail(id: String)
    case profile
    case search(query: String)
    case kycReview
}

// MARK: - App authority

@Observable
@MainActor
final class SampleAppAuthority {
    let store: NavigationStore<SampleRoute>
    let modal = ModalStore<SampleRoute>()
    let flow = FlowStore<SampleRoute>()
    let debouncedSearch: DebouncingNavigator<NavigationStore<SampleRoute>, ContinuousClock>
    let deepLinkHandler: DeepLinkEffectHandler<SampleRoute>

    /// In a real app this would be backed by Keychain or a session
    /// service. The sample uses a small Sendable wrapper around a
    /// `Mutex<Bool>` so the @Sendable `isAuthenticated` closure
    /// inside the pipeline can read it from any executor while the
    /// UI flips it on @MainActor.
    private let session: AuthSession

    var isAuthenticated: Bool {
        get { session.isAuthenticated }
        set { session.isAuthenticated = newValue }
    }

    init() {
        let store = NavigationStore<SampleRoute>()
        let session = AuthSession()
        self.store = store
        self.session = session
        self.debouncedSearch = DebouncingNavigator(
            wrapping: store,
            interval: .milliseconds(250)
        )
        self.deepLinkHandler = DeepLinkEffectHandler(
            pipeline: Self.makeDeepLinkPipeline(session: session),
            navigator: AnyBatchNavigator(store)
        )
    }

    func handleDeepLink(_ url: URL) {
        switch deepLinkHandler.handle(url) {
        case .pending(let pending):
            // The handler retains `pending` in memory until sign-in completes
            // and the app asks it to resume.
            Logger(subsystem: "io.innosquad.innorouter.sample", category: "deeplink")
                .info("deferred deep link until auth: \(pending.url.absoluteString, privacy: .private)")
        case .executed, .executionFailed, .applicationRejected,
             .rejected, .unhandled, .invalidURL, .missingDeepLinkURL,
             .noPendingDeepLink:
            break
        }
    }

    func searchTyped(_ query: String) async {
        // Debouncing collapses rapid keystrokes into a single
        // navigation per quiet window.
        await debouncedSearch.debouncedExecute(.replace([.search(query: query)]))
    }

    nonisolated private static func searchQuery(from url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "q" || $0.name == "query" }?
            .value ?? ""
    }

    nonisolated private static func makeDeepLinkPipeline(
        session: AuthSession
    ) -> DeepLinkPipeline<SampleRoute> {
        DeepLinkPipeline(
            allowedSchemes: ["app"],
            allowedHosts: ["sample"],
            customResolver: { url in
                switch url.path {
                case "/profile": .profile
                case "/kyc":     .kycReview
                case "/search":  .search(query: searchQuery(from: url))
                default:         nil
                }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    route == .profile || route == .kycReview
                },
                isAuthenticated: { [session] in
                    session.isAuthenticated
                }
            )
        )
    }
}

// MARK: - Sendable session wrapper

private final class AuthSession: Sendable {
    private let storage: Mutex<Bool>

    init(initial: Bool = false) {
        self.storage = Mutex(initial)
    }

    var isAuthenticated: Bool {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
