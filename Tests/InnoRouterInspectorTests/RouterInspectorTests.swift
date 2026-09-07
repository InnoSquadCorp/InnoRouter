import Foundation
import Synchronization
import SwiftUI
import Testing

import InnoRouter
import InnoRouterInspector

private enum InspectorRoute: Route {
    case secret(String)
    case settings
}

private enum InspectorDeepLinkRoute: DeepLinkRoute {
    case item(Int)

    static let deepLinkCatalog = DeepLinkRouteCatalog(
        schemes: ["example"],
        hosts: ["app"],
        entries: [
            .init(
                routeCase: "item",
                pattern: "/items/:id",
                parameters: [
                    .init(name: "id", typeName: "Int", source: .path, isRequired: true),
                ]
            ),
        ]
    )
    static let supportsPureDeepLinkExplanation = true

    static func resolveDeepLink(_ url: URL) -> Self? {
        guard let value = Int(url.lastPathComponent) else { return nil }
        return .item(value)
    }
}

private enum UntrustedInspectorDeepLinkRoute: DeepLinkRoute {
    case item

    static let deepLinkCatalog = DeepLinkRouteCatalog(
        schemes: ["innorouter"],
        hosts: ["app.example.com"],
        entries: [.init(routeCase: "item", pattern: "/products/:id")]
    )

    static func resolveDeepLink(_ url: URL) -> Self? {
        preconditionFailure("Inspector must not execute an app-owned resolver: \(url)")
    }
}

private struct SideEffectingInspectorID: Hashable, Sendable, DeepLinkParameterValue {
    static let calls = Mutex(0)
    let value: String

    static func parseDeepLinkParameter(_ value: String) -> Self? {
        calls.withLock { $0 += 1 }
        return Self(value: value)
    }
}

@Router(
    deepLinkSchemes: ["https"],
    deepLinkHosts: ["review.example.com"],
    inspectorCatalog: true
)
private enum SideEffectingInspectorRoute {
    @DeepLink("/detail/:id")
    case detail(id: SideEffectingInspectorID)

    var destination: some View { EmptyView() }
}

@Suite("Router inspector")
@MainActor
struct RouterInspectorTests {
    @Test("Deep-link analysis projects catalog attempts without route payloads")
    func deepLinkAnalysis() throws {
        let valid = try #require(URL(string: "example://app/items/42"))
        let invalid = try #require(URL(string: "example://app/items/secret-value"))

        let accepted = RouterInspectorDeepLinkAnalyzer.analyze(
            valid,
            as: InspectorDeepLinkRoute.self
        )
        let rejected = RouterInspectorDeepLinkAnalyzer.analyze(
            invalid,
            as: InspectorDeepLinkRoute.self
        )

        #expect(accepted.decision == "accepted item via /items/:id")
        #expect(accepted.attempts.map(\.outcome) == [.resolved])
        #expect(rejected.decision == "rejected: parameter-conversion-failed")
        #expect(rejected.attempts.map(\.outcome) == [.candidate])
        #expect(!rejected.decision.contains("secret-value"))
        let shared = RouterInspectorDeepLinkAnalyzer.shareSummary(rejected)
        #expect(!shared.contains("secret-value"))
        #expect(shared.contains("/items/:id"))
        _ = RouterInspectorDeepLinkView(
            InspectorDeepLinkRoute.self,
            initialURL: valid.absoluteString
        ).body

        let store = RouterStore<InspectorDeepLinkRoute>()
        _ = RouterInspectorDeepLinkView(
            store: store,
            initialURL: valid.absoluteString
        ).body
    }

    @Test("App-owned resolvers are not called by read-only analysis without explicit opt-in")
    func customResolverIsNotEvaluated() throws {
        let url = try #require(URL(string: "innorouter://app.example.com/products/42"))
        let analysis = RouterInspectorDeepLinkAnalyzer.analyze(
            url,
            as: UntrustedInspectorDeepLinkRoute.self
        )

        #expect(analysis.decision == "not-evaluated: custom-resolver")
        #expect(analysis.attempts.map(\.outcome) == [.candidate])
    }

    @Test("Macro preview does not execute custom parameter conversion")
    func customParameterConversionIsNotEvaluated() throws {
        SideEffectingInspectorID.calls.withLock { $0 = 0 }
        let url = try #require(URL(string: "https://review.example.com/detail/secret"))

        let analysis = RouterInspectorDeepLinkAnalyzer.preview(
            url,
            as: SideEffectingInspectorRoute.self,
            from: .rootStack
        )

        #expect(SideEffectingInspectorID.calls.withLock { $0 } == 0)
        #expect(analysis.decision == "not-evaluated: custom-resolver")
        #expect(analysis.proposedState == nil)
    }

    @Test("Deep-link preview is pure and explicit execution uses store policies")
    func deepLinkPreviewAndExecutionBoundary() async throws {
        let url = try #require(URL(string: "example://app/items/42"))
        let lockedStore = RouterStore<InspectorDeepLinkRoute>(configuration: .init(
            policies: [RouterPolicy(name: "inspector-lock") { transition in
                transition.context.source == .inspector ? .reject("locked") : .allow
            }]
        ))

        let preview = RouterInspectorDeepLinkAnalyzer.preview(
            url,
            as: InspectorDeepLinkRoute.self,
            from: lockedStore.state
        )
        #expect(preview.diff?.changes.isEmpty == false)
        #expect(preview.proposedState != nil)
        #expect(lockedStore.revision == 0)
        #expect(lockedStore.state.root == .stack())

        guard case .rejected(_, _, _, .policy(name: "inspector-lock", message: "locked")) =
                await RouterInspectorDeepLinkAnalyzer.execute(url, on: lockedStore) else {
            Issue.record("Expected policy rejection")
            return
        }
        #expect(lockedStore.revision == 0)

        let openStore = RouterStore<InspectorDeepLinkRoute>()
        guard case .applied = await RouterInspectorDeepLinkAnalyzer.execute(url, on: openStore) else {
            Issue.record("Expected explicit execution")
            return
        }
        #expect(openStore.state.root == .stack(path: [.item(42)]))
    }

    @Test("History is bounded, pausable, clearable, and serializable")
    func lifecycle() throws {
        let recorder = RouterInspectorRecorder(capacity: 2)
        recorder.record(domain: .router, description: .init(name: "one"))
        recorder.record(domain: .application, description: .init(name: "two"))
        recorder.record(domain: .router, description: .init(name: "three"))

        #expect(recorder.entries.map(\.name) == ["two", "three"])
        recorder.toggleBookmark(recorder.entries[0].id)
        #expect(recorder.isBookmarked(recorder.entries[0].id))

        recorder.pause()
        recorder.record(domain: .application, description: .init(name: "dropped"))
        #expect(recorder.entries.count == 2)

        recorder.resume()
        let timestamp = Date(timeIntervalSince1970: 42)
        let data = try recorder.encodedSnapshot(generatedAt: timestamp)
        let decoded = try JSONDecoder().decode(RouterInspectorSnapshot.self, from: data)
        #expect(decoded.generatedAt == timestamp)
        #expect(decoded.entries == recorder.entries)
        #expect(decoded.bookmarkedEntryIDs == recorder.bookmarkedEntryIDs)

        recorder.clear()
        #expect(recorder.entries.isEmpty)
        #expect(recorder.bookmarkedEntryIDs.isEmpty)
    }

    @Test("Diagnostic bundles include environment identity and remain redacted")
    func diagnosticBundle() throws {
        let secret = "never-include-this-route-payload"
        let recorder = RouterInspectorRecorder()
        let state = try RouterState<InspectorRoute>(
            root: .stack(path: [.secret(secret)])
        )
        recorder.record(
            domain: .router,
            description: .init(
                name: "transition.committed",
                outcome: .accepted,
                state: RouterInspectorProjection.tree(from: state)
            )
        )
        let generatedAt = Date(timeIntervalSince1970: 42)

        let data = try recorder.encodedDiagnosticBundle(
            platform: .visionOS,
            generatedAt: generatedAt
        )
        let bundle = try JSONDecoder().decode(
            RouterInspectorDiagnosticBundle.self,
            from: data
        )

        #expect(bundle.formatVersion == 1)
        #expect(bundle.frameworkVersion == InnoRouterVersion.current)
        #expect(bundle.platform == .visionOS)
        #expect(bundle.snapshot.generatedAt == generatedAt)
        #expect(bundle.snapshot.entries == recorder.entries)
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        let second = try recorder.encodedDiagnosticBundle(
            platform: .visionOS,
            generatedAt: generatedAt
        )
        #expect(data == second)
    }

    @Test("Diagnostic bundle bookmarks encode deterministically")
    func diagnosticBundleBookmarkEncoding() throws {
        let firstID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let secondID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let entries = [
            RouterInspectorEntry(
                id: secondID,
                timestamp: Date(timeIntervalSince1970: 2),
                domain: .router,
                name: "second",
                outcome: .informational
            ),
            RouterInspectorEntry(
                id: firstID,
                timestamp: Date(timeIntervalSince1970: 1),
                domain: .router,
                name: "first",
                outcome: .informational
            ),
        ]
        let bundle = RouterInspectorDiagnosticBundle(
            platform: .macOS,
            snapshot: RouterInspectorSnapshot(
                generatedAt: Date(timeIntervalSince1970: 3),
                entries: entries,
                bookmarkedEntryIDs: [secondID, firstID]
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let snapshot = try #require(object["snapshot"] as? [String: Any])
        let bookmarks = try #require(
            snapshot["bookmarkedEntryIDs"] as? [String]
        )
        #expect(bookmarks == [firstID.uuidString, secondID.uuidString])
        #expect(try JSONDecoder().decode(
            RouterInspectorDiagnosticBundle.self,
            from: data
        ) == bundle)
    }

    @Test("Timing correlation and pause-on-rejection stay payload safe")
    func timingAndRejectionBreakpoint() {
        let recorder = RouterInspectorRecorder()
        let transitionID = RouterTransitionID().description
        recorder.record(
            domain: .router,
            description: .init(
                name: "transition.started",
                metadata: ["transitionID": transitionID]
            ),
            timestamp: Date(timeIntervalSince1970: 10)
        )
        recorder.record(
            domain: .router,
            description: .init(
                name: "policy.prepared",
                metadata: ["transitionID": transitionID]
            ),
            timestamp: Date(timeIntervalSince1970: 10.025)
        )
        recorder.setPauseOnRejection(true)
        recorder.record(
            domain: .router,
            description: .init(
                name: "transition.rejected",
                outcome: .rejected,
                metadata: ["transitionID": transitionID]
            ),
            timestamp: Date(timeIntervalSince1970: 10.1)
        )

        #expect(recorder.entries[1].metadata["elapsedSincePreviousMilliseconds"] == "25.000")
        #expect(recorder.entries[2].metadata["elapsedSincePreviousMilliseconds"] == "75.000")
        #expect(recorder.entries[2].metadata["durationMilliseconds"] == "100.000")
        #expect(recorder.isPaused)
        recorder.record(domain: .router, description: .init(name: "dropped"))
        #expect(recorder.entries.count == 3)

        recorder.resume()
        recorder.record(
            domain: .application,
            description: .init(name: "application.denied", outcome: .rejected)
        )
        #expect(recorder.isPaused)
    }

    @Test("Bounded history releases timing state for evicted transitions")
    func boundedTimingState() {
        let recorder = RouterInspectorRecorder(capacity: 1)
        recorder.record(
            domain: .router,
            description: .init(
                name: "transition.started",
                metadata: ["transitionID": "evicted"]
            ),
            timestamp: Date(timeIntervalSince1970: 1)
        )
        recorder.record(
            domain: .application,
            description: .init(name: "replacement")
        )
        recorder.record(
            domain: .router,
            description: .init(
                name: "transition.rejected",
                outcome: .rejected,
                metadata: ["transitionID": "evicted"]
            ),
            timestamp: Date(timeIntervalSince1970: 2)
        )

        #expect(recorder.entries.count == 1)
        #expect(recorder.entries[0].metadata["durationMilliseconds"] == nil)
    }

    @Test("Canonical timeline correlates transitions without route payloads")
    func canonicalTimeline() async throws {
        let secret = "do-not-expose-canonical-route"
        let recorder = RouterInspectorRecorder()
        let store = RouterStore<InspectorRoute>()
        let subscription = recorder.attach(to: store)

        _ = await store.perform(.push(.secret(secret)))
        for _ in 0..<50 where recorder.entries.count < 2 {
            await Task.yield()
        }

        let entries = recorder.entries
        #expect(entries.map(\.name) == ["transition.started", "transition.committed"])
        #expect(entries[0].metadata["transitionID"] == entries[1].metadata["transitionID"])
        #expect(entries[0].metadata["action"] == "push")
        #expect(entries[1].metadata["after"]?.contains("routes=1") == true)
        let encoded = String(decoding: try recorder.encodedSnapshot(), as: UTF8.self)
        #expect(!encoded.contains(secret))
        subscription.cancel()
    }

    @Test("Policy deferral does not trigger a rejection breakpoint")
    func deferralIsNotRejection() async {
        let recorder = RouterInspectorRecorder()
        recorder.setPauseOnRejection(true)
        let deferralID = RouterDeferralID()
        let store = RouterStore<InspectorRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { _ in
                        .deferRequest(deferralID)
                    }
                ]
            )
        )
        let subscription = recorder.attach(to: store)

        _ = await store.perform(.push(.settings))
        for _ in 0..<50 where recorder.entries.count < 3 {
            await Task.yield()
        }

        #expect(recorder.entries.map(\.name) == [
            "transition.started",
            "policy.prepared",
            "transition.deferred",
        ])
        #expect(recorder.entries[1].outcome == .informational)
        #expect(!recorder.isPaused)
        subscription.cancel()
    }

    @Test("Platform adaptations appear in the canonical redacted timeline")
    func platformAdaptationTimeline() async {
        let recorder = RouterInspectorRecorder()
        let store = RouterStore<InspectorRoute>()
        let subscription = recorder.attach(to: store)

        store.reportPlatformAdaptation(
            .tabBadgeVisualUnavailable(scope: "private-tab-name", count: 2)
        )
        for _ in 0..<20 where recorder.entries.isEmpty {
            await Task.yield()
        }

        #expect(recorder.entries.map(\.name) == ["platform.adapted"])
        #expect(recorder.entries.first?.metadata["adaptation"] == "tab.badge.visualUnavailable")
        let description = String(describing: recorder.entries.first)
        #expect(!description.contains("private-tab-name"))
        subscription.cancel()
    }

    @Test("Custom formatters are an explicit payload detail opt-in")
    func customFormatter() async {
        let recorder = RouterInspectorRecorder()
        let store = RouterStore<InspectorRoute>()
        let subscription = recorder.attach(
            to: store.events,
            domain: .application,
            formatter: RouterInspectorFormatter { event in
                .init(name: String(describing: event))
            }
        )

        _ = await store.perform(.push(.settings))
        for _ in 0..<20 where recorder.entries.count < 2 {
            await Task.yield()
        }

        #expect(!recorder.entries.isEmpty)
        subscription.cancel()
    }

    @Test("State trees and diffs expose structure without route payloads")
    func structuralProjection() throws {
        let before = try RouterState<InspectorRoute>()
        let after = try RouterState<InspectorRoute>(
            root: .stack(
                path: [.secret("never-export-this")],
                presentation: .init(route: .settings, style: .sheet)
            )
        )

        let tree = RouterInspectorProjection.tree(from: after)
        let diff = RouterInspectorProjection.diff(from: before, to: after)
        let data = try JSONEncoder().encode(tree)
        let encoded = String(decoding: data, as: UTF8.self)

        #expect(tree.root.details["routes"] == "1")
        #expect(tree.root.details["presentation"] == "sheet")
        #expect(diff.changes.contains { $0.field == "routes" })
        #expect(!encoded.contains("never-export-this"))
    }

    @Test("Default state exports redact scope and scene identifiers")
    func identifierRedaction() throws {
        let sensitiveScope = RouterScopeID("account/private-document")
        let windowID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let container = try RouterContainerState<InspectorRoute>(
            style: .tabs,
            selection: sensitiveScope,
            branches: [
                RouterBranch(id: sensitiveScope),
                RouterBranch(
                    id: "other",
                    node: .container(
                        try RouterContainerState<InspectorRoute>(
                            style: .custom("nested"),
                            branches: [RouterBranch(id: "nested/secret")]
                        )
                    )
                ),
            ],
            badges: [sensitiveScope: 3]
        )
        let state = try RouterState<InspectorRoute>(
            root: .container(container),
            windows: [.init(id: windowID, route: .settings)],
            immersiveSpace: .init(id: "private-immersive-id", route: .settings)
        )

        let tree = RouterInspectorProjection.tree(from: state)
        let encoded = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)
        let identifiers = tree.flattenedNodes.map(\.id)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(!encoded.contains(sensitiveScope.rawValue))
        #expect(!encoded.contains("nested/secret"))
        #expect(!encoded.contains(windowID.uuidString))
        #expect(!encoded.contains("private-immersive-id"))
        #expect(tree.root.details["selection"] == "branch[0]")
        #expect(tree.windows.first?.children.count == 1)
        #expect(tree.immersiveSpace?.children.count == 1)
    }

    @Test("Replay preview runs the pure reducer without mutating input state")
    func pureReplay() throws {
        let initial = try RouterState<InspectorRoute>()
        let proposed = try RouterReducer.reduce(.push(.settings), from: initial)
        let transition = RouterTransition(
            id: .init(),
            action: .push(.settings),
            initialState: initial,
            proposedState: proposed,
            initialRevision: 0
        )

        let preview = RouterInspectorReplay.preview(transition)

        #expect(preview.status == .matchedProposal)
        #expect(preview.state?.root.details["routes"] == "1")
        #expect(initial.root == .stack())
    }

    @Test("Inspector view composes from recorder state")
    func viewConstruction() {
        let recorder = RouterInspectorRecorder()
        recorder.record(domain: .router, description: .init(name: "transition.committed"))

        _ = RouterInspectorView(recorder: recorder).body
    }

    @Test("Exported sessions import, compare, and step without a live store")
    func importedPlayback() throws {
        let firstState = RouterInspectorProjection.tree(
            from: try RouterState<InspectorRoute>()
        )
        let secondState = RouterInspectorProjection.tree(
            from: try RouterState<InspectorRoute>(root: .stack(path: [.settings]))
        )
        let firstEntry = RouterInspectorEntry(
            domain: .router,
            name: "first",
            outcome: .informational,
            state: firstState
        )
        let secondEntry = RouterInspectorEntry(
            domain: .router,
            name: "second",
            outcome: .accepted,
            state: secondState
        )
        let snapshot = RouterInspectorSnapshot(entries: [firstEntry, secondEntry])
        let data = try JSONEncoder().encode(snapshot)
        let recorder = RouterInspectorRecorder()

        let imported = try recorder.importSnapshot(from: data)
        let playback = RouterInspectorPlayback(snapshot: imported)

        #expect(recorder.entries == snapshot.entries)
        recorder.toggleBookmark(firstEntry.id)
        let arbitraryDiff = recorder.comparison(from: firstEntry.id, to: secondEntry.id)
        #expect(arbitraryDiff?.changes.contains { $0.field == "routes" } == true)
        #expect(playback.currentEntry?.name == "first")
        #expect(!playback.canStepBackward)
        #expect(playback.canStepForward)
        playback.stepForward()
        #expect(playback.currentEntry?.name == "second")
        playback.setComparisonEntry(firstEntry.id)
        #expect(playback.comparisonToSelectedState?.changes.contains { $0.field == "routes" } == true)
        let containsRouteChange = playback.comparisonToPreviousState?.changes.contains { change in
            change.field == "routes"
        }
        #expect(containsRouteChange == true)
    }

    @Test("Import limits reject bytes and entries before timeline mutation")
    func boundedImportPreflight() throws {
        let recorder = RouterInspectorRecorder(
            importLimits: .init(
                maximumEncodedByteCount: 1_024,
                maximumEntryCount: 1
            )
        )
        let oversized = Data(repeating: 0x20, count: 1_025)
        #expect(
            throws: RouterInspectorImportError.encodedDataTooLarge(
                actualByteCount: 1_025,
                maximumByteCount: 1_024
            )
        ) {
            try recorder.importSnapshot(from: oversized)
        }

        let entries = [
            RouterInspectorEntry(
                domain: .router,
                name: "first",
                outcome: .informational
            ),
            RouterInspectorEntry(
                domain: .router,
                name: "second",
                outcome: .accepted
            ),
        ]
        let data = try JSONEncoder().encode(
            RouterInspectorSnapshot(entries: entries)
        )
        #expect(
            throws: RouterInspectorImportError.tooManyEntries(
                actualCount: 2,
                maximumCount: 1
            )
        ) {
            try recorder.importSnapshot(from: data)
        }
        #expect(recorder.entries.isEmpty)
    }

    @Test("Import preflight requires the snapshot entries envelope")
    func malformedImportEnvelope() {
        let recorder = RouterInspectorRecorder()

        #expect(throws: RouterInspectorImportError.malformedSnapshotEnvelope) {
            try recorder.importSnapshot(from: Data("{\"generatedAt\":0}".utf8))
        }
        #expect(recorder.entries.isEmpty)
    }

    @Test("Snapshot comparison uses only final redacted states")
    func snapshotComparison() throws {
        let before = RouterInspectorSnapshot(
            entries: [
                RouterInspectorEntry(
                    domain: .router,
                    name: "before",
                    outcome: .informational,
                    state: RouterInspectorProjection.tree(from: try RouterState<InspectorRoute>())
                )
            ]
        )
        let after = RouterInspectorSnapshot(
            entries: [
                RouterInspectorEntry(
                    domain: .router,
                    name: "after",
                    outcome: .accepted,
                    state: RouterInspectorProjection.tree(
                        from: try RouterState<InspectorRoute>(
                            root: .stack(path: [.secret("redacted")])
                        )
                    )
                )
            ]
        )

        guard let diff = RouterInspectorComparison.finalStates(in: before, and: after) else {
            Issue.record("Expected comparable final states")
            return
        }
        #expect(diff.changes.contains { $0.field == "routes" })
        #expect(!String(decoding: try JSONEncoder().encode(after), as: UTF8.self).contains("redacted"))
    }
}
