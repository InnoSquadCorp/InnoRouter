// MARK: - MultiPlatformExample.swift
// Demonstrates running the same InnoRouter flow on every Apple
// platform. `NavigationHost` works uniformly; `NavigationSplitHost`
// is opt-in on non-watchOS surfaces where SwiftUI's NavigationSplitView
// is available.
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouter

@Routable
enum MultiPlatformRoute {
    case inbox
    case message(id: String)
    case preferences
}

/// Entry point. Picks the split host on platforms that support
/// `NavigationSplitView` (iOS / iPadOS / macOS / tvOS / visionOS) and
/// falls back to a single-column `NavigationHost` on watchOS.
struct MultiPlatformExampleView: View {
    @State private var store: NavigationStore<MultiPlatformRoute> = NavigationStore()

    var body: some View {
        #if !os(watchOS)
        NavigationSplitHost(store: store) {
            MultiPlatformSidebar()
        } destination: { route in
            MultiPlatformDestination(route: route)
        } root: {
            Text("Select a conversation")
                .navigationTitle("InnoRouter")
        }
        #else
        // watchOS falls back to a single-column navigation host because
        // `NavigationSplitView` is unavailable on watchOS. The
        // `NavigationHost` body is otherwise identical, so every other
        // platform shares the same route vocabulary.
        NavigationHost(store: store) { route in
            MultiPlatformDestination(route: route)
        } root: {
            MultiPlatformInbox()
        }
        #endif
    }
}

struct MultiPlatformSidebar: View {
    @EnvironmentNavigationIntent(MultiPlatformRoute.self)
    private var navigationIntent

    var body: some View {
        List {
            Button("Inbox") { navigationIntent(.go(.inbox)) }
            Button("Preferences") { navigationIntent(.go(.preferences)) }
        }
        .navigationTitle("InnoRouter")
    }
}

struct MultiPlatformInbox: View {
    @EnvironmentNavigationIntent(MultiPlatformRoute.self)
    private var navigationIntent

    var body: some View {
        List {
            Button("Message 1") { navigationIntent(.go(.message(id: "1"))) }
            Button("Message 2") { navigationIntent(.go(.message(id: "2"))) }
            Button("Preferences") { navigationIntent(.go(.preferences)) }
        }
        .navigationTitle("Inbox")
    }
}

struct MultiPlatformDestination: View {
    let route: MultiPlatformRoute

    var body: some View {
        switch route {
        case .inbox:
            MultiPlatformInbox()
        case .message(let id):
            Text("Message \(id)")
                .navigationTitle("Message")
        case .preferences:
            Text("Preferences")
                .navigationTitle("Preferences")
        }
    }
}
