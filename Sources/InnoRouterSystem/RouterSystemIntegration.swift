// MARK: - RouterSystemIntegration.swift
// InnoRouterSystem - App Intents and Handoff bridges
// Copyright © 2026 Inno Squad. All rights reserved.

import AppIntents
import Foundation
import SwiftUI

import InnoRouterCore
import InnoRouterDeepLink
import InnoRouterSwiftUI

/// Converts a typed deep-link route into the system's open-URL intent.
///
/// Applications keep their concrete `AppIntent` and `AppShortcutsProvider`;
/// `perform()` can return this bridge so the app opens through the same
/// fail-closed URL contract used by InnoRouter.
public struct RouterOpenURLIntentBuilder<R: DeepLinkRoute>: Sendable {
    public let origin: DeepLinkOrigin

    public init(origin: DeepLinkOrigin) {
        self.origin = origin
    }

    public func url(for route: R) -> URL? {
        route.deepLinkURL(origin: origin)
    }

    public func intent(for route: R) -> OpenURLIntent? {
        url(for: route).map(OpenURLIntent.init)
    }
}

/// A stable, app-owned identifier mapped to one typed shortcut route.
public struct RouterShortcutRoute<R: DeepLinkRoute>: Sendable, Hashable, Identifiable {
    public let id: String
    public let route: R

    public init(id: String, route: R) {
        precondition(!id.isEmpty, "Router shortcut identifiers must not be empty")
        self.id = id
        self.route = route
    }
}

/// Typed route catalog shared by an application's concrete App Intents and
/// `AppShortcutsProvider` declaration.
///
/// Phrases, titles, authentication policy, and discoverability remain in the
/// application target because they are localized product behavior.
public struct RouterShortcutCatalog<R: DeepLinkRoute>: Sendable {
    public let origin: DeepLinkOrigin
    public let entries: [RouterShortcutRoute<R>]
    private let routesByID: [String: R]

    public init(origin: DeepLinkOrigin, entries: [RouterShortcutRoute<R>]) {
        precondition(
            Set(entries.map(\.id)).count == entries.count,
            "Router shortcut identifiers must be unique"
        )
        self.origin = origin
        self.entries = entries
        self.routesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0.route) }
        )
    }

    public func route(for identifier: String) -> R? {
        routesByID[identifier]
    }

    public func url(for identifier: String) -> URL? {
        route(for: identifier)?.deepLinkURL(origin: origin)
    }

    public func intent(for identifier: String) -> OpenURLIntent? {
        url(for: identifier).map(OpenURLIntent.init)
    }
}

/// Metadata used to publish a route as an `NSUserActivity` Handoff item.
public struct RouterHandoffConfiguration<R: DeepLinkRoute>: Sendable {
    public let activityType: String
    public let origin: DeepLinkOrigin
    public let title: @Sendable (R) -> String

    /// Creates a Handoff configuration for a universal-link origin.
    ///
    /// `NSUserActivity.webpageURL` rejects custom schemes with an Objective-C
    /// exception, so invalid or non-web origins fail safely before a view can
    /// publish them.
    public init?(
        activityType: String,
        origin: DeepLinkOrigin,
        title: @escaping @Sendable (R) -> String
    ) {
        guard !activityType.isEmpty,
              origin.scheme == "https" || origin.scheme == "http" else {
            return nil
        }
        self.activityType = activityType
        self.origin = origin
        self.title = title
    }
}

public extension View {
    /// Publishes the current typed route for Handoff without storing route
    /// payloads in `userInfo`; the canonical, allowlisted URL is the payload.
    func routerHandoff<R: DeepLinkRoute>(
        _ route: R?,
        configuration: RouterHandoffConfiguration<R>
    ) -> some View {
        userActivity(configuration.activityType, element: route) { route, activity in
            activity.title = configuration.title(route)
            activity.webpageURL = route.deepLinkURL(origin: configuration.origin)
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = true
        }
    }
}

/// Executes a continued Handoff activity through the canonical plan pipeline.
@MainActor
public func continueRouterHandoff<R: Route>(
    _ activity: NSUserActivity,
    store: RouterStore<R>,
    pipeline: RouterLinkPipeline<R>
) async -> RouterLinkExecution<R>? {
    guard let url = activity.webpageURL else {
        return nil
    }
    return await store.handle(url, using: pipeline, source: .handoff)
}
