import Foundation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum TabSelectionRaceRoute: String, DestinationRoute, RouterTabRoute {
    case home
    case inbox

    enum Tab: String, RouterTab {
        case home
        case inbox

        var title: LocalizedStringResource { self == .home ? "Home" : "Inbox" }
        var systemImage: String { self == .home ? "house" : "tray" }
        var routerScopeID: RouterScopeID { RouterScopeID(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home),
        .init(tab: .inbox, root: .inbox),
    ]

    @MainActor
    static func destination(for route: Self) -> some View {
        Text(route.rawValue)
    }
}

@MainActor
private final class TabSelectionRaceGate {
    private let entered: AsyncStream<Void>
    private let didEnter: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, didEnter) = AsyncStream<Void>.makeStream()
        (releases, releaseContinuation) = AsyncStream<Void>.makeStream()
    }

    func wait() async {
        didEnter.yield(())
        for await _ in releases { break }
    }

    func waitUntilEntered() async throws {
        _ = try await firstElement(from: entered, what: "tab race policy entered")
    }

    func release() {
        releaseContinuation.finish()
    }
}

@MainActor
private final class TabSelectionRaceFixture {
    let store: RouterStore<TabSelectionRaceRoute>
    let scope: RouterScope<TabSelectionRaceRoute>
    let host: RouterTabHost<TabSelectionRaceRoute>
    let terminals: AsyncStream<RouterEvent<TabSelectionRaceRoute>>
    let queued: AsyncStream<RouterTransitionID>

    init(policies: [RouterPolicy<TabSelectionRaceRoute>] = []) throws {
        let (terminals, didFinish) = AsyncStream<RouterEvent<TabSelectionRaceRoute>>.makeStream()
        let (queued, didQueue) = AsyncStream<RouterTransitionID>.makeStream()
        var configuration = RouterStoreConfiguration(policies: policies, onEvent: { event in
            switch event {
            case .committed(_, _, _, _, let context),
                 .unchanged(_, _, _, let context),
                 .deferred(_, _, _, _, let context),
                 .rejected(_, _, _, _, let context):
                if context.source == .system { didFinish.yield(event) }
            default:
                break
            }
        })
        configuration.runtimeDependencies.didQueueRequest = { id in
            didQueue.yield(id)
        }
        let store = try RouterStore(initialState: try Self.state(), configuration: configuration)
        self.store = store
        self.scope = store.scope()
        self.host = RouterTabHost(store: store)
        self.terminals = terminals
        self.queued = queued
    }

    static func state(
        style: RouterContainerStyle = .tabs
    ) throws -> RouterState<TabSelectionRaceRoute> {
        let split: RouterSplitState? = style == .split
            ? try RouterSplitState(sidebar: "home", detail: "inbox")
            : nil
        return try RouterState(root: .container(.init(
            style: style,
            selection: "home",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "inbox")],
            split: split
        )))
    }

    func requestInbox() {
        host.requestSelection("inbox", in: scope)
    }

    func nextTerminal() async throws -> RouterEvent<TabSelectionRaceRoute> {
        try await firstElement(from: terminals, what: "tab selection terminal event")
    }

    func waitUntilQueued() async throws {
        _ = try await firstElement(from: queued, what: "tab selection enqueued")
    }
}

@Suite("Router tab selection races", .tags(.unit))
@MainActor
struct RouterTabSelectionRaceTests {
    @Test(
        "A queued tab callback cannot select a replacement split or custom root",
        arguments: [RouterContainerStyle.split, .custom("wizard")]
    )
    func queuedSelectionRejectsReplacementTopology(style: RouterContainerStyle) async throws {
        let gate = TabSelectionRaceGate()
        defer { gate.release() }
        let fixture = try TabSelectionRaceFixture(policies: [
            RouterPolicy(name: "hold-root-replacement") { transition in
                if case .apply = transition.action { await gate.wait() }
                return .allow
            },
        ])
        let replacement = try TabSelectionRaceFixture.state(style: style)
        let replace = Task { @MainActor in
            await fixture.store.perform(.apply(.init(state: replacement)))
        }
        try await gate.waitUntilEntered()

        // Submission still sees tabs. Both replacement branches retain the
        // requested ID, so the old implementation can incorrectly select it.
        fixture.requestInbox()
        try await fixture.waitUntilQueued()
        gate.release()
        guard case .applied = await replace.value else {
            Issue.record("Expected root replacement to commit")
            return
        }
        guard case .rejected(_, let state, let revision, let reason, _) =
            try await fixture.nextTerminal() else {
            Issue.record("Expected the queued tab callback to reject")
            return
        }

        #expect(reason == .mutation(.incompatibleNavigationTopology(.root)))
        #expect(state == replacement)
        #expect(revision == 1)
        #expect(fixture.store.state == replacement)
        #expect(fixture.store.revision == 1)
        #expect(fixture.scope.reconciliationRevision == 1)
    }

    @Test("A queued tab callback survives an unrelated mutation within the same tabs")
    func queuedSelectionPreservesUnrelatedChange() async throws {
        let gate = TabSelectionRaceGate()
        defer { gate.release() }
        let fixture = try TabSelectionRaceFixture(policies: [
            RouterPolicy(name: "hold-badge-update") { transition in
                if case .setBadge = transition.action { await gate.wait() }
                return .allow
            },
        ])
        let update = Task { @MainActor in
            await fixture.store.perform(.setBadge(4, for: "home"))
        }
        try await gate.waitUntilEntered()
        fixture.requestInbox()
        try await fixture.waitUntilQueued()
        gate.release()
        guard case .applied = await update.value,
              case .committed = try await fixture.nextTerminal() else {
            Issue.record("Expected the badge and queued selection to commit")
            return
        }

        let expected = try RouterReducer.reduce(
            .select("inbox"),
            from: RouterReducer.reduce(.setBadge(4, for: "home"), from: TabSelectionRaceFixture.state())
        )
        #expect(fixture.store.state == expected)
        #expect(fixture.store.revision == 2)
        #expect(fixture.scope.reconciliationRevision == 1)
    }

    @Test(
        "A rebased deferred tab callback cannot select a replacement split or custom root",
        arguments: [RouterContainerStyle.split, .custom("wizard")]
    )
    func deferredSelectionRejectsReplacementTopology(style: RouterContainerStyle) async throws {
        let deferral = RouterDeferralID()
        let fixture = try deferredSelectionFixture(deferral)
        fixture.requestInbox()
        guard case .deferred = try await fixture.nextTerminal() else {
            Issue.record("Expected the tab callback to defer")
            return
        }
        let replacement = try TabSelectionRaceFixture.state(style: style)
        guard case .applied = await fixture.store.perform(.apply(.init(state: replacement))) else {
            Issue.record("Expected root replacement to commit")
            return
        }

        // Rebase removes the revision guard so this regression isolates the
        // host's execution-time topology precondition, including deferral.
        let outcome = await fixture.store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState)
        guard case .rejected(_, let state, let revision, let reason) = outcome else {
            Issue.record("Expected the rebased tab callback to reject")
            return
        }
        #expect(reason == .mutation(.incompatibleNavigationTopology(.root)))
        #expect(state == replacement)
        #expect(revision == 1)
        #expect(fixture.store.state == replacement)
        #expect(fixture.store.revision == 1)
        #expect(fixture.store.deferredTransitions.isEmpty)
        #expect(fixture.scope.reconciliationRevision == 2)
    }

    @Test("A rebased deferred tab callback preserves unrelated changes within the same tabs")
    func deferredSelectionPreservesUnrelatedChange() async throws {
        let deferral = RouterDeferralID()
        let fixture = try deferredSelectionFixture(deferral)
        fixture.requestInbox()
        guard case .deferred = try await fixture.nextTerminal(),
              case .applied = await fixture.store.perform(.setBadge(4, for: "home")) else {
            Issue.record("Expected selection to defer and the badge update to commit")
            return
        }
        let beforeResume = fixture.store.state
        let outcome = await fixture.store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState)
        guard case .applied = outcome else {
            Issue.record("Expected a valid tab callback to resume")
            return
        }

        #expect(fixture.store.state == (try RouterReducer.reduce(.select("inbox"), from: beforeResume)))
        #expect(fixture.store.revision == 2)
        #expect(fixture.store.deferredTransitions.isEmpty)
        #expect(fixture.scope.reconciliationRevision == 2)
    }

    @Test("An ordinary tab callback commits through the system pipeline")
    func ordinarySelectionCommits() async throws {
        let fixture = try TabSelectionRaceFixture()
        fixture.requestInbox()
        guard case .committed = try await fixture.nextTerminal() else {
            Issue.record("Expected a tab selection commit")
            return
        }

        #expect(fixture.scope.observedSelection == "inbox")
        #expect(fixture.store.revision == 1)
        #expect(fixture.scope.reconciliationRevision == 1)
    }

    @Test("A topology-compatible tab callback still honors policy rejection")
    func selectionStillHonorsPolicyRejection() async throws {
        let fixture = try TabSelectionRaceFixture(policies: [
            RouterPolicy(name: "selection-policy") { _ in .reject("denied") },
        ])
        fixture.requestInbox()
        guard case .rejected(_, _, _, let reason, _) = try await fixture.nextTerminal() else {
            Issue.record("Expected policy rejection")
            return
        }

        #expect(reason == .policy(name: "selection-policy", message: "denied"))
        #expect(fixture.scope.observedSelection == "home")
        #expect(fixture.store.revision == 0)
        #expect(fixture.scope.reconciliationRevision == 1)
    }

    private func deferredSelectionFixture(
        _ id: RouterDeferralID
    ) throws -> TabSelectionRaceFixture {
        try TabSelectionRaceFixture(policies: [
            RouterPolicy(name: "defer-selection") { transition in
                if case .select = transition.action { return .deferRequest(id) }
                return .allow
            },
        ])
    }
}
