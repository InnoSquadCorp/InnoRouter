import Foundation
import SwiftUI
import Testing

import InnoRouter
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

private enum DefaultLinkTabRoute: String, Codable, DestinationRoute, RouterTabRoute, DeepLinkRoute {
    case home, settings, detail, sheet

    enum Tab: String, RouterTab {
        case home, settings
        var title: LocalizedStringResource { self == .home ? "Home" : "Settings" }
        var systemImage: String { "circle" }
        var routerScopeID: RouterScopeID { .init(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home), .init(tab: .settings, root: .settings),
    ]

    static func resolveDeepLink(_ url: URL) -> Self? {
        guard url.scheme == "links", url.host == "tabs.test" else { return nil }
        switch url.path {
        case "/detail": return .detail
        case "/settings": return .settings
        default: return nil
        }
    }

    static func destination(for route: Self) -> some View { Text(route.rawValue) }
}

@MainActor
private final class DefaultLinkEventLog<R: Route> {
    var rejections: [RouterRejectionReason] = []
    var commits = 0

    func record(_ event: RouterEvent<R>) {
        switch event {
        case .rejected(_, _, _, let reason, _): rejections.append(reason)
        case .committed: commits += 1
        default: break
        }
    }
}

/// A macro-first host without `RouterLinkHandling` applies a resolved link as
/// one Store request. These tests drive the same submission path that the
/// native `onOpenURL` modifier uses.
@Suite("Default link execution", .serialized)
@MainActor
struct RouterDefaultLinkExecutionTests {
    private typealias R = DefaultLinkTabRoute

    private func makeFixture(
        policies: [RouterPolicy<R>] = []
    ) throws -> (RouterStore<R>, RouterTabHost<R>, DefaultLinkEventLog<R>) {
        let catalog = try RouterTabCatalog(R.routerTabs)
        let initial = try RouterState<R>(root: .container(.init(
            style: .tabs, selection: "home", branches: [.init(id: "home"), .init(id: "settings")]
        )))
        let store = try RouterStore(
            initialState: initial,
            configuration: .init(hostDescriptor: catalog.hostDescriptor(), policies: policies)
        )
        let log = DefaultLinkEventLog<R>()
        store.addSynchronousEventObserver { log.record($0) }
        return (store, try RouterTabHost(store: store, catalog: catalog), log)
    }

    private func submit(
        _ string: String, store: RouterStore<R>, host: RouterTabHost<R>, arbiter: RouterDeepLinkArbiter,
        depth: Int = 0
    ) throws -> URL {
        let url = try #require(URL(string: string))
        submitRouterPlanLink(
            R.self, url: url, scope: store.scope(),
            context: RouterDeepLinkContext(arbiter: arbiter, depth: depth),
            source: RouterDeepLinkSource(), handling: nil, fallbackPlan: host.defaultLinkPlanBuilder
        )
        return url
    }

    /// Flushes the arbiter and waits for the request it started to terminate.
    private func deliver(
        _ url: URL, arbiter: RouterDeepLinkArbiter, until isSettled: @MainActor () -> Bool
    ) async throws {
        arbiter.flush(url)
        try await waitUntil("the link request reached a terminal event", condition: isSettled)
    }

    @Test("A destination link pushes onto the selected tab")
    func destinationLinkPushes() async throws {
        let (store, host, log) = try makeFixture()
        let arbiter = RouterDeepLinkArbiter()
        let url = try submit("links://tabs.test/detail", store: store, host: host, arbiter: arbiter)
        try await deliver(url, arbiter: arbiter) { log.commits == 1 }

        #expect(store.scope(at: ["home"]).node == .stack(path: [.detail]))
        #expect(log.rejections.isEmpty)
    }

    @Test("A tab-root link selects its tab")
    func tabRootLinkSelects() async throws {
        let (store, host, log) = try makeFixture()
        let arbiter = RouterDeepLinkArbiter()
        let url = try submit("links://tabs.test/settings", store: store, host: host, arbiter: arbiter)
        try await deliver(url, arbiter: arbiter) { log.commits == 1 }

        #expect(store.scope().observedSelection == "settings")
    }

    @Test("A link the host cannot apply is reported as a rejected request")
    func linkDuringSheetIsReported() async throws {
        let (store, host, log) = try makeFixture()
        let presented = await store.scope(at: ["home"])
            .perform(.present(.init(route: .sheet, style: .sheet)))
        guard case .applied = presented else {
            Issue.record("Sheet setup did not apply: \(presented)")
            return
        }
        let before = store.state
        let revision = store.revision

        let arbiter = RouterDeepLinkArbiter()
        let url = try submit("links://tabs.test/detail", store: store, host: host, arbiter: arbiter)
        try await deliver(url, arbiter: arbiter) { !log.rejections.isEmpty }

        // Rejected, not applied: one visible terminal event and no mutation.
        #expect(log.rejections.count == 1)
        guard case .mutation = log.rejections.first else {
            Issue.record("Expected a mutation rejection, got \(String(describing: log.rejections.first))")
            return
        }
        #expect(store.state == before)
        #expect(store.revision == revision)
    }

    @Test("A commit that lands before the link executes is preserved")
    func interveningCommitSurvives() async throws {
        let (store, host, log) = try makeFixture()
        let arbiter = RouterDeepLinkArbiter()
        // The host submits at URL arrival; the Store executes turns later.
        let url = try submit("links://tabs.test/detail", store: store, host: host, arbiter: arbiter)

        let badge = await store.perform(.setBadge(3, for: "settings"))
        guard case .applied = badge else {
            Issue.record("Badge setup did not apply: \(badge)")
            return
        }
        try await deliver(url, arbiter: arbiter) { log.commits == 2 }

        guard case .container(let container) = store.state.root else {
            Issue.record("Expected a tab container")
            return
        }
        #expect(store.scope(at: ["home"]).node == .stack(path: [.detail]))
        #expect(container.badges["settings"] == 3)
    }

    @Test("A link that became inapplicable before it executes is rejected, not applied stale")
    func linkValidatedAtExecution() async throws {
        let (store, host, log) = try makeFixture()
        let arbiter = RouterDeepLinkArbiter()
        // Applicable at arrival…
        let url = try submit("links://tabs.test/detail", store: store, host: host, arbiter: arbiter)
        // …but a sheet is presented before the request runs.
        let presented = await store.scope(at: ["home"])
            .perform(.present(.init(route: .sheet, style: .sheet)))
        guard case .applied = presented else {
            Issue.record("Sheet setup did not apply: \(presented)")
            return
        }
        let before = store.state

        try await deliver(url, arbiter: arbiter) { !log.rejections.isEmpty }

        #expect(store.state == before, "A plan derived at arrival would have removed the sheet")
        #expect(log.rejections.count == 1)
    }

    /// Presents a sheet over the home tab, which makes a destination link
    /// inapplicable to that host.
    private func coverWithSheet(_ store: RouterStore<R>) async {
        let presented = await store.scope(at: ["home"]).perform(.present(.init(route: .sheet, style: .sheet)))
        guard case .applied = presented else {
            Issue.record("Sheet setup did not apply: \(presented)")
            return
        }
    }

    @Test("An outer host that cannot apply a link yields to a nested host that can")
    func inapplicableOuterHostYields() async throws {
        let (outerStore, outerHost, outerLog) = try makeFixture()
        let (innerStore, innerHost, innerLog) = try makeFixture()
        await coverWithSheet(outerStore)
        let outerBefore = outerStore.state

        let arbiter = RouterDeepLinkArbiter()
        let url = try submit("links://tabs.test/detail", store: outerStore, host: outerHost, arbiter: arbiter)
        _ = try submit("links://tabs.test/detail", store: innerStore, host: innerHost, arbiter: arbiter, depth: 1)
        try await deliver(url, arbiter: arbiter) { innerLog.commits == 1 }

        #expect(innerStore.scope(at: ["home"]).node == .stack(path: [.detail]))
        #expect(outerStore.state == outerBefore)
        #expect(outerLog.rejections.isEmpty)
    }

    @Test("The yield does not depend on which host submitted first")
    func inapplicableOuterHostYieldsWhenSubmittedLast() async throws {
        let (outerStore, outerHost, outerLog) = try makeFixture()
        let (innerStore, innerHost, innerLog) = try makeFixture()
        await coverWithSheet(outerStore)

        let arbiter = RouterDeepLinkArbiter()
        let url = try submit(
            "links://tabs.test/detail", store: innerStore, host: innerHost, arbiter: arbiter, depth: 1
        )
        _ = try submit("links://tabs.test/detail", store: outerStore, host: outerHost, arbiter: arbiter)
        try await deliver(url, arbiter: arbiter) { innerLog.commits == 1 }

        #expect(innerStore.scope(at: ["home"]).node == .stack(path: [.detail]))
        #expect(outerLog.rejections.isEmpty)
    }

    @Test("When no host can apply a link the outermost host reports the rejection")
    func outermostHostReportsWhenNoneCanApply() async throws {
        let (outerStore, outerHost, outerLog) = try makeFixture()
        let (innerStore, innerHost, innerLog) = try makeFixture()
        await coverWithSheet(outerStore)
        await coverWithSheet(innerStore)
        let innerBefore = innerStore.state

        let arbiter = RouterDeepLinkArbiter()
        let url = try submit(
            "links://tabs.test/detail", store: innerStore, host: innerHost, arbiter: arbiter, depth: 1
        )
        _ = try submit("links://tabs.test/detail", store: outerStore, host: outerHost, arbiter: arbiter)
        try await deliver(url, arbiter: arbiter) { !outerLog.rejections.isEmpty }

        #expect(outerLog.rejections.count == 1)
        #expect(innerLog.rejections.isEmpty)
        #expect(innerStore.state == innerBefore)
    }

    @Test("When both hosts can apply a link the outermost host applies it")
    func outermostApplicableHostWins() async throws {
        let (outerStore, outerHost, outerLog) = try makeFixture()
        let (innerStore, innerHost, innerLog) = try makeFixture()

        let arbiter = RouterDeepLinkArbiter()
        let url = try submit(
            "links://tabs.test/detail", store: innerStore, host: innerHost, arbiter: arbiter, depth: 1
        )
        _ = try submit("links://tabs.test/detail", store: outerStore, host: outerHost, arbiter: arbiter)
        try await deliver(url, arbiter: arbiter) { outerLog.commits == 1 }

        #expect(outerStore.scope(at: ["home"]).node == .stack(path: [.detail]))
        #expect(innerLog.commits == 0)
        #expect(innerStore.scope(at: ["home"]).node == .stack(path: []))
    }

    @Test("A deferred link request does not keep its Store alive")
    func deferredLinkDoesNotRetainStore() async throws {
        weak var releasedStore: RouterStore<R>?
        do {
            let deferral = RouterDeferralID()
            let (store, host, _) = try makeFixture(
                policies: [.init(name: "hold") { _ in .deferRequest(deferral) }]
            )
            releasedStore = store
            let deferred = TestCell(false)
            store.addSynchronousEventObserver { event in
                if case .deferred = event { deferred.value = true }
            }
            let arbiter = RouterDeepLinkArbiter()
            let url = try submit("links://tabs.test/detail", store: store, host: host, arbiter: arbiter)
            try await deliver(url, arbiter: arbiter) { deferred.value }
        }
        // The Store now holds the deferred request and its plan builder; the
        // builder must not hold the Store back.
        try await waitUntil("the Store was released") { releasedStore == nil }
    }
}
