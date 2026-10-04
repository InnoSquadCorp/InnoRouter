import Foundation
import Observation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Scope lookup resource admission", .timeLimit(.minutes(1)))
@MainActor
struct RouterScopeResourceAdmissionTests {
    private enum R: String, Route, Codable { case home, detail }
    private enum OversizedPath: CaseIterable { case depth, branchBytes, immersiveBytes, windowDepth }
    @MainActor private final class Capture { var scope: RouterScope<R>? }

    @Test("Exactly admitted missing paths retain stable identity and ordinary expired authority")
    func admittedMissingIdentity() async throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 4, maximumGraphDepth: 2))
        let store = try RouterStore<R>(configuration: .init(resourceBudget: budget))
        for path in [RouterScopePath([.branch(.init("éé"))]), .immersiveSpace("éé")] {
            let scope = store.scope(at: path)
            #expect(scope === store.scope(at: path))
            #expect(scope.path == path)
            guard case .rejected(_, _, _, .mutation(.expiredScope(let rejectedPath))) = await scope.performRoot(.push(.detail)) else {
                Issue.record("Admitted absent scopes must preserve ordinary expired ownership"); return
            }
            #expect(rejectedPath == path)
            #expect(store.state == .rootStack)
        }
    }

    @Test("Retained missing scopes observe their own appearance without unrelated invalidation")
    func preciseMissingAppearance() async throws {
        let store = RouterStore<R>()
        let missing = store.scope(at: ["left"])
        let updates = Mutex(0)
        let capture = Capture()
        withObservationTracking { _ = store.scope(at: ["left"]) } onChange: {
            updates.withLock { $0 += 1 }
            MainActor.assumeIsolated { capture.scope = store.scope(at: ["left"]) }
        }
        _ = await store.perform(.push(.detail))
        #expect(updates.withLock { $0 } == 0)
        let target = try RouterState<R>(root: .container(.init(style: .tabs, selection: "left", branches: [
            .init(id: "left", node: .stack()), .init(id: "right", node: .stack()),
        ])))
        _ = await store.perform(.apply(.init(state: target)))
        #expect(updates.withLock { $0 } == 1)
        let live = try #require(capture.scope)
        #expect(live !== missing)
        #expect(live === store.scope(at: ["left"]))
        #expect(live.node == .stack())
        #expect(missing.node == nil)
    }

    @Test("Missing and removed cache overhead follows caller-retained scopes and releases with them")
    func retainedCacheAccounting() async throws {
        let store = RouterStore<R>()
        var retained: [RouterScope<R>] = []
        for index in 0..<20 {
            retained.append(store.scope(at: [.branch(.init("missing-\(index)"))]))
            let id = UUID()
            _ = await store.perform(.openWindow(.init(id: id, route: .home)))
            retained.append(store.scope(at: .window(id)))
            _ = await store.perform(.dismissWindow(id))
        }
        #expect(retained.allSatisfy { $0.node == nil })
        #expect(store.scopeLifetimes.count == 1)
        #expect(store.cachedScopeCount == retained.count)
        #expect(store.scopeLifetimeObservations.count == retained.count)
        retained.removeAll()
        store.compactDeadScopes()
        #expect(store.scopes.isEmpty)
        #expect(store.scopeLifetimeObservations.isEmpty)
    }

    @Test("A live-path lifetime subscription survives unrelated weak-cache compaction", arguments: [false, true])
    func observationWithoutRetainedProjection(retainProjection: Bool) async throws {
        let store = try RouterStore<R>(initialState: RouterState(root: .container(.init(
            style: .tabs, selection: "left", branches: [
                .init(id: "left", node: .stack()), .init(id: "right", node: .stack()),
            ]
        ))))
        let updates = Mutex(0)
        var retained: RouterScope<R>?
        weak var captured: RouterScope<R>?
        withObservationTracking {
            let scope = store.scope(at: ["left"])
            captured = scope
            if retainProjection { retained = scope }
        } onChange: { updates.withLock { $0 += 1 } }
        #expect((captured != nil) == retainProjection)
        // The unrelated lookup invokes the real public factory's compaction.
        _ = store.scope(at: ["right"])
        guard case .unchanged = await store.replaceSubtree(at: ["left"], with: .stack()) else {
            Issue.record("Equal replacement must replace ownership without assigning state"); return
        }
        #expect(updates.withLock { $0 } == 1)
        #expect(store.revision == 0)
        if let retained { #expect(retained.node == nil) }
    }

    @Test("Oversized lookup paths stay inert and reject before callbacks or cache ownership", arguments: OversizedPath.allCases, [false, true])
    private func oversizedLookupPath(kind: OversizedPath, performAtRoot: Bool) async throws {
        let id = UUID()
        let path: RouterScopePath
        let failure: RouterResourceLimitFailure
        switch kind {
        case .depth:
            path = ["a", "b"]
            failure = .init(resource: "request.scopeDepth", actual: 3, maximum: 2)
        case .branchBytes:
            path = [.branch(.init("ééx"))]
            failure = .init(resource: "state.metadataBytes", actual: 5, maximum: 4)
        case .immersiveBytes:
            path = .immersiveSpace("ééx")
            failure = .init(resource: "state.metadataBytes", actual: 5, maximum: 4)
        case .windowDepth:
            path = .init(["a", "b"], domain: .window(id))
            failure = .init(resource: "request.scopeDepth", actual: 3, maximum: 2)
        }
        let generations = Mutex(0), policies = Mutex(0), requests = Mutex(0)
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 4, maximumGraphDepth: 2))
        let initial = try RouterState<R>(windows: kind == .windowDepth ? [.init(id: id, route: .home)] : [])
        let store = try RouterStore(initialState: initial, configuration: .init(
            resourceBudget: budget,
            policies: [.init(name: "must-not-run") { _ in policies.withLock { $0 += 1 }; return .allow }],
            authorization: .init(
                generation: { generations.withLock { $0 += 1 }; return 0 },
                requiresAuthorization: { _ in false }, authorize: { true }
            )
        ))
        let observer = store.addSynchronousRequestObserver { _ in requests.withLock { $0 += 1 } }
        defer { store.removeSynchronousRequestObserver(observer) }

        let scope = store.scope(at: path)
        #expect(scope.path == path)
        #expect(scope.node == nil)
        #expect(scope.state == nil)
        #expect(scope.observedSceneRootRoute == nil)
        #expect(scope.observedWindows.isEmpty)
        #expect(scope.observedImmersiveSpace == nil)
        #expect(scope.sceneLifetime == nil)
        #expect(store.scopes.isEmpty)
        #expect(store.scopeLifetimeObservations.isEmpty)
        let isUncached = scope !== store.scope(at: path)
        #expect(isUncached)

        let outcome = performAtRoot
            ? await scope.performRoot(.push(.detail))
            : await scope.perform(.push(.detail))
        if case .rejected(_, _, _, .resourceLimit(let actual)) = outcome {
            #expect(actual == failure)
        } else {
            Issue.record("Oversized scope must report its precise resource admission failure")
        }
        #expect(generations.withLock { $0 } == 0)
        #expect(policies.withLock { $0 } == 0)
        #expect(requests.withLock { $0 } == 0)
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(store.scopes.isEmpty)
        #expect(store.scopeLifetimeObservations.isEmpty)
    }

    @Test("Oversized scope dispatch and typed presentation surfaces preserve precise resource rejection")
    func oversizedPresentationSurfaces() async throws {
        let generations = Mutex(0), requests = Mutex(0)
        let store = try RouterStore<R>(configuration: .init(
            resourceBudget: .init(snapshot: try .init(maximumGraphDepth: 2)),
            authorization: .init(
                generation: { generations.withLock { $0 += 1 }; return 0 },
                requiresAuthorization: { _ in false }, authorize: { true }
            )
        ))
        _ = await store.perform(.presentAlert(.init(content: .init(title: "Question", actions: [
            .init(id: "choose", label: "Choose"),
        ]))))
        let handle = try #require(store.presentationHandle())
        let initial = store.state
        generations.withLock { $0 = 0 }
        let observer = store.addSynchronousRequestObserver { _ in requests.withLock { $0 += 1 } }
        defer { store.removeSynchronousRequestObserver(observer) }
        let scope = store.scope(at: ["a", "b"])
        let reason = RouterRejectionReason.resourceLimit(.init(resource: "request.scopeDepth", actual: 3, maximum: 2))

        let navigation: RouterPresentationOutcome<String> = await scope.present(.home)
        let transient = await scope.present(RouterTransientPresentationRequest<String>.alert(title: "Question", actions: [
            .init(id: "choose", label: "Choose", value: "value"),
        ]))
        #expect(navigation == .rejected(reason))
        #expect(transient == .rejected(reason))
        for typed in [false, true] {
            do {
                if typed {
                    try await scope.finishPresentation(RouterPresentationRequest<R, String>(route: .home), returning: "value")
                } else {
                    try await scope.finishPresentation(returning: "value")
                }
                Issue.record("Oversized scope completion must reject")
            } catch {
                #expect(error as? RouterPresentationCompletionError == .dismissalRejected(reason))
            }
        }
        let outcomes = [
            await scope.dispatch(.push(.detail)).value,
            await scope.dispatchRoot(.push(.detail)).value,
            await scope.dismissPresentation(using: handle),
            await scope.selectPresentationAction("choose", using: handle),
        ]
        for outcome in outcomes {
            guard case .rejected(_, _, _, let actual) = outcome else {
                Issue.record("Oversized scope request must reject"); continue
            }
            #expect(actual == reason)
        }
        #expect(generations.withLock { $0 } == 0)
        #expect(requests.withLock { $0 } == 0)
        #expect(store.state == initial)
        #expect(store.revision == 1)
        #expect(store.scopes.isEmpty)
        #expect(store.scopeLifetimeObservations.isEmpty)
    }
}
