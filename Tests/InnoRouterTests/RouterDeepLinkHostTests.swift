// MARK: - RouterDeepLinkHostTests.swift
// InnoRouter Tests - macro-first host deep-link handling
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum HostDeepLinkRoute: DestinationRoute, DeepLinkRoute {
    case detail(id: String)
    case settings

    static func resolveDeepLink(_ url: URL) -> Self? {
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count == 2, components[0] == "detail" {
            return .detail(id: components[1])
        }
        return components == ["settings"] ? .settings : nil
    }

    static func destination(for route: Self) -> some View {
        Text(String(describing: route))
    }
}

private enum FeatureDeepLinkRoute: DestinationRoute, DeepLinkRoute {
    case feature

    static func resolveDeepLink(_ url: URL) -> Self? {
        url.path == "/feature" ? .feature : nil
    }

    static func destination(for route: Self) -> some View {
        Text(String(describing: route))
    }
}

private enum PlainHostRoute: DestinationRoute {
    case home

    static func destination(for route: Self) -> some View {
        Text(String(describing: route))
    }
}

private enum HostDeepLinkTab: String, DestinationRoute, DeepLinkRoute, RouterTab {
    case home
    case settings

    var title: String { rawValue.capitalized }
    var systemImage: String { self == .home ? "house" : "gear" }

    static func resolveDeepLink(_ url: URL) -> Self? {
        url.path == "/settings" ? .settings : nil
    }

    static func destination(for route: Self) -> some View {
        Text(route.title)
    }
}

@MainActor
private final class RouterDeepLinkRecorder<Value> {
    var values: [Value] = []
}

@Suite("Macro-first host deep links", .tags(.unit))
@MainActor
struct RouterDeepLinkHostTests {
    @Test("A scene identifier owns one arbitration authority")
    func sceneRegistryScopesArbiters() {
        let first = RouterDeepLinkSceneArbiterRegistry.arbiter(for: "scene-a")
        let sameScene = RouterDeepLinkSceneArbiterRegistry.arbiter(for: "scene-a")
        let otherScene = RouterDeepLinkSceneArbiterRegistry.arbiter(for: "scene-b")

        #expect(first === sameScene)
        #expect(first !== otherScene)
    }

    @Test("A DeepLinkRoute candidate pushes through its FlowStore")
    func pushesResolvedRoute() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/detail/42"))
        let arbiter = RouterDeepLinkArbiter()
        let source = RouterDeepLinkSource()
        let store = FlowStore<HostDeepLinkRoute>()

        #expect(
            submitRouterDeepLink(
                HostDeepLinkRoute.self,
                url: url,
                context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
                source: source
            ) { route in
                store.send(.push(route))
            }
        )
        arbiter.flush(url)

        #expect(store.path == [.push(.detail(id: "42"))])
    }

    @Test("A route without DeepLinkRoute capability is a no-op")
    func ignoresPlainRoute() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let recorder = RouterDeepLinkRecorder<PlainHostRoute>()

        #expect(
            !submitRouterDeepLink(
                PlainHostRoute.self,
                url: url,
                context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
                source: RouterDeepLinkSource()
            ) { route in
                recorder.values.append(route)
            }
        )
        arbiter.flush(url)

        #expect(recorder.values.isEmpty)
    }

    @Test("Tab deep links select instead of pushing")
    func selectsResolvedTab() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let state = RouterTabState(initial: HostDeepLinkTab.home)

        #expect(
            submitRouterDeepLink(
                HostDeepLinkTab.self,
                url: url,
                context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
                source: RouterDeepLinkSource()
            ) { route in
                state.send(.select(route))
            }
        )
        arbiter.flush(url)

        #expect(state.selection == .settings)
    }

    @Test("The shallowest matching host owns one incoming URL")
    func outerMatchWins() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let recorder = RouterDeepLinkRecorder<String>()

        submitRouterDeepLink(
            HostDeepLinkRoute.self,
            url: url,
            context: RouterDeepLinkContext(arbiter: arbiter, depth: 2),
            source: RouterDeepLinkSource()
        ) { _ in
            recorder.values.append("inner")
        }
        submitRouterDeepLink(
            HostDeepLinkRoute.self,
            url: url,
            context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
            source: RouterDeepLinkSource()
        ) { _ in
            recorder.values.append("outer")
        }
        arbiter.flush(url)

        #expect(recorder.values == ["outer"])
    }

    @Test("An inner feature handles a URL that the outer route cannot resolve")
    func innerFallbackHandles() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/feature"))
        let arbiter = RouterDeepLinkArbiter()
        let recorder = RouterDeepLinkRecorder<String>()

        #expect(
            !submitRouterDeepLink(
                HostDeepLinkRoute.self,
                url: url,
                context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
                source: RouterDeepLinkSource()
            ) { _ in
                recorder.values.append("outer")
            }
        )
        #expect(
            submitRouterDeepLink(
                FeatureDeepLinkRoute.self,
                url: url,
                context: RouterDeepLinkContext(arbiter: arbiter, depth: 1),
                source: RouterDeepLinkSource()
            ) { _ in
                recorder.values.append("inner")
            }
        )
        arbiter.flush(url)

        #expect(recorder.values == ["inner"])
    }

    @Test("Duplicate callbacks from one host execute only once per flush")
    func duplicateCallbackCoalesces() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let source = RouterDeepLinkSource()
        let recorder = RouterDeepLinkRecorder<HostDeepLinkRoute>()
        let context = RouterDeepLinkContext(arbiter: arbiter, depth: 0)

        for _ in 0..<2 {
            submitRouterDeepLink(
                HostDeepLinkRoute.self,
                url: url,
                context: context,
                source: source
            ) { route in
                recorder.values.append(route)
            }
        }
        arbiter.flush(url)

        #expect(recorder.values == [.settings])
    }

    @Test("The same URL can execute again after the previous event flushes")
    func repeatedEventExecutesAgain() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let source = RouterDeepLinkSource()
        let recorder = RouterDeepLinkRecorder<HostDeepLinkRoute>()
        let context = RouterDeepLinkContext(arbiter: arbiter, depth: 0)

        for _ in 0..<2 {
            submitRouterDeepLink(
                HostDeepLinkRoute.self,
                url: url,
                context: context,
                source: source
            ) { route in
                recorder.values.append(route)
            }
            arbiter.flush(url)
        }

        #expect(recorder.values == [.settings, .settings])
    }

    @Test("A submitted URL flushes on the next main-actor turn")
    func scheduledFlush() async throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let recorder = RouterDeepLinkRecorder<HostDeepLinkRoute>()

        submitRouterDeepLink(
            HostDeepLinkRoute.self,
            url: url,
            context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
            source: RouterDeepLinkSource()
        ) { route in
            recorder.values.append(route)
        }

        for _ in 0..<10 where recorder.values.isEmpty {
            await Task.yield()
        }
        #expect(recorder.values == [.settings])
    }

    @Test("Different incoming URLs keep independent pending actions")
    func differentURLsExecuteIndependently() throws {
        let settings = try #require(URL(string: "innorouter://app.example.com/settings"))
        let detail = try #require(URL(string: "innorouter://app.example.com/detail/42"))
        let arbiter = RouterDeepLinkArbiter()
        let source = RouterDeepLinkSource()
        let recorder = RouterDeepLinkRecorder<HostDeepLinkRoute>()
        let context = RouterDeepLinkContext(arbiter: arbiter, depth: 0)

        for url in [settings, detail] {
            submitRouterDeepLink(
                HostDeepLinkRoute.self,
                url: url,
                context: context,
                source: source
            ) { route in
                recorder.values.append(route)
            }
        }
        arbiter.flush(settings)
        arbiter.flush(detail)

        #expect(recorder.values == [.settings, .detail(id: "42")])
    }

    @Test("Same-depth matches execute the first candidate only")
    func sameDepthKeepsFirstCandidate() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/settings"))
        let arbiter = RouterDeepLinkArbiter()
        let recorder = RouterDeepLinkRecorder<String>()
        let context = RouterDeepLinkContext(arbiter: arbiter, depth: 1)

        for label in ["first", "second"] {
            submitRouterDeepLink(
                HostDeepLinkRoute.self,
                url: url,
                context: context,
                source: RouterDeepLinkSource()
            ) { _ in
                recorder.values.append(label)
            }
        }
        arbiter.flush(url)

        #expect(recorder.values == ["first"])
    }

    @Test("A modal tail still rejects automatic pushes")
    func modalTailInvariant() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/detail/blocked"))
        let arbiter = RouterDeepLinkArbiter()
        let recorder = RouterDeepLinkRecorder<FlowEvent<HostDeepLinkRoute>>()
        let store = FlowStore<HostDeepLinkRoute>(
            initial: [.sheet(.settings)],
            configuration: FlowStoreConfiguration { recorder.values.append($0) }
                .withMacroFirstDiagnostics()
        )

        submitRouterDeepLink(
            HostDeepLinkRoute.self,
            url: url,
            context: RouterDeepLinkContext(arbiter: arbiter, depth: 0),
            source: RouterDeepLinkSource()
        ) { route in
            store.send(.push(route))
        }
        arbiter.flush(url)

        #expect(store.path == [.sheet(.settings)])
        #expect(
            recorder.values.contains(
                .intentRejected(
                    .push(.detail(id: "blocked")),
                    .pushBlockedByModalTail
                )
            )
        )
    }
}
