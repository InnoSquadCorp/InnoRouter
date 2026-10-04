import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Scope scene metadata reentrancy", .timeLimit(.minutes(1)))
@MainActor
struct RouterScopeSceneMetadataReentrancyTests {
    private enum R: String, Route, Codable { case home, detail, replacement }
    private enum ObservationPoint: CaseIterable { case lifetime, state, revision }
    private let windowID = UUID(uuidString: "EAF53AD7-441F-408E-96EB-9BC424F34791")!
    private let immersiveID = "scene-metadata"

    @MainActor
    private final class Capture { var scope: RouterScope<R>? }

    private func path(immersive: Bool) -> RouterScopePath {
        immersive ? .immersiveSpace(immersiveID) : .window(windowID)
    }

    private func state(immersive: Bool) throws -> RouterState<R> {
        if immersive {
            return try RouterState(immersiveSpace: .init(id: immersiveID, route: .home, node: .stack(path: [.home])))
        }
        return try RouterState(windows: [.init(id: windowID, route: .home, node: .stack(path: [.home]))])
    }

    private func expectCurrentMetadata(_ scope: RouterScope<R>, in store: RouterStore<R>) throws {
        #expect(scope.matchesCurrentLifetime)
        let lifetime = try #require(scope.sceneLifetime)
        let isCurrent = store.matchesSceneRequestLifetime(lifetime)
        #expect(isCurrent)
        #expect(lifetime == store.sceneRequestLifetime(at: scope.path))
    }

    private func exerciseFeatureMetadata(_ scope: RouterScope<R>, in store: RouterStore<R>) async throws {
        let mapping = RouterFeatureMapping<R, R>(
            id: "identity", namespace: "identity", route: .init(embed: { $0 }, extract: { $0 })
        )
        let feature = RouterFeatureScope(parent: scope, mapping: mapping)
        var observations: [RouterRequestObservation<R>] = []
        let observer = store.addSynchronousRequestObserver { observations.append($0) }
        defer { store.removeSynchronousRequestObserver(observer) }
        guard case .applied = await feature.perform(.push(.detail)) else {
            Issue.record("Fresh feature action must apply"); return
        }
        guard case .applied = await feature.perform(.apply(.init(state: .rootStack(path: [.replacement])))) else {
            Issue.record("Fresh feature plan must apply"); return
        }
        #expect(observations.count == 2)
        guard observations.count == 2,
              case .featureAction(let actionPath, let actionLifetime, _) = observations[0].semantics,
              case .featurePlan(let planPath, let planLifetime, _, _) = observations[1].semantics else {
            Issue.record("Expected feature action and plan semantics"); return
        }
        #expect(actionPath == scope.path)
        #expect(planPath == scope.path)
        let canonical = store.sceneRequestLifetime(at: scope.path)
        #expect(actionLifetime == canonical)
        #expect(planLifetime == canonical)
        let actionIsCurrent = actionLifetime.map(store.matchesSceneRequestLifetime) ?? false
        let planIsCurrent = planLifetime.map(store.matchesSceneRequestLifetime) ?? false
        #expect(actionIsCurrent)
        #expect(planIsCurrent)
    }

    @Test("New scene scopes acquired during commit retain current feature metadata", arguments: [false, true], ObservationPoint.allCases)
    private func newSceneReacquisition(immersive: Bool, observation: ObservationPoint) async throws {
        let store = RouterStore<R>()
        let scenePath = path(immersive: immersive)
        let missing = store.scope(at: scenePath)
        let missingLifetime = missing.sceneLifetime
        let root = store.scope()
        let capture = Capture()
        withObservationTracking {
            switch observation {
            case .lifetime: _ = store.scope(at: scenePath)
            case .state: _ = store.state
            case .revision: _ = store.revision
            }
        } onChange: {
            MainActor.assumeIsolated { capture.scope = store.scope(at: scenePath) }
        }
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let target = try state(immersive: immersive)
        guard case .applied = try await store.restore(from: codec.encode(target), using: codec) else {
            Issue.record("Expected a newly created scene"); return
        }
        let fresh = try #require(capture.scope)
        #expect(fresh !== missing)
        #expect(fresh === store.scope(at: scenePath))
        #expect(fresh.node == target.node(at: scenePath))
        try expectCurrentMetadata(fresh, in: store)
        #expect(missing.sceneLifetime == missingLifetime)
        #expect(missing.node == nil)
        #expect(missing.state == nil)
        #expect(root.sceneLifetime == nil)
        guard case .rejected(_, _, _, .mutation(.expiredScope(scenePath))) = await missing.perform(.push(.detail)) else {
            Issue.record("Missing capture must remain inert"); return
        }
        try await exerciseFeatureMetadata(fresh, in: store)
    }

    @Test("Equal restore retains native scene identity while replacing runtime ownership", arguments: [false, true])
    func retainedSceneIdentity(immersive: Bool) async throws {
        let target = try state(immersive: immersive)
        let store = try RouterStore(initialState: target)
        let scenePath = path(immersive: immersive)
        let old = store.scope(at: scenePath)
        let nativeLifetime = old.sceneLifetime
        let capture = Capture()
        withObservationTracking { _ = store.scope(at: scenePath) } onChange: {
            MainActor.assumeIsolated { capture.scope = store.scope(at: scenePath) }
        }
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        guard case .unchanged = try await store.restore(from: codec.encode(target), using: codec) else {
            Issue.record("Expected equal restore"); return
        }
        let fresh = try #require(capture.scope)
        #expect(fresh !== old)
        #expect(fresh.sceneLifetime == nativeLifetime)
        #expect(old.sceneLifetime == nativeLifetime)
        #expect(old.node == nil)
        #expect(old.state == nil)
        #expect(store.revision == 0)
        try expectCurrentMetadata(fresh, in: store)
        guard case .rejected(_, _, _, .mutation(.expiredScope(scenePath))) = await old.perform(.push(.detail)) else {
            Issue.record("Restored scope must not revive old runtime ownership"); return
        }
        try await exerciseFeatureMetadata(fresh, in: store)
    }

    @Test("Removed scenes keep expired metadata when their IDs are recreated", arguments: [false, true])
    func expiredSceneDoesNotRetarget(immersive: Bool) async throws {
        let store = try RouterStore(initialState: try state(immersive: immersive))
        let scenePath = path(immersive: immersive)
        let old = store.scope(at: scenePath)
        let oldLifetime = try #require(old.sceneLifetime)
        let removal: RouterAction<R> = immersive ? .dismissImmersiveSpace : .dismissWindow(windowID)
        guard case .applied = await store.perform(removal) else {
            Issue.record("Expected scene removal"); return
        }
        let creation: RouterAction<R> = immersive
            ? .enterImmersiveSpace(.init(id: immersiveID, route: .home))
            : .openWindow(.init(id: windowID, route: .home))
        guard case .applied = await store.perform(creation) else {
            Issue.record("Expected reused scene ID creation"); return
        }
        let fresh = store.scope(at: scenePath)
        try expectCurrentMetadata(fresh, in: store)
        #expect(old.sceneLifetime == oldLifetime)
        #expect(fresh.sceneLifetime != oldLifetime)
        let oldIsCurrent = store.matchesSceneRequestLifetime(oldLifetime)
        #expect(!oldIsCurrent)
        #expect(old.node == nil)
        #expect(old.state == nil)
        guard case .rejected(_, _, _, .mutation(.expiredScope(scenePath))) = await old.perform(.push(.detail)) else {
            Issue.record("Expired scene must not retarget recreated scene"); return
        }
        try await exerciseFeatureMetadata(fresh, in: store)
    }

    @Test("Application root and branch scopes keep absent scene metadata")
    func applicationScopesRemainUnchanged() async throws {
        let target = try RouterState<R>(root: .container(RouterContainerState(
            style: .tabs, selection: "left", branches: [
                .init(id: "left", node: .stack(path: [.home])),
                .init(id: "right", node: .stack()),
            ]
        )))
        let store = try RouterStore(initialState: target)
        let root = store.scope(), left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        _ = await left.perform(.push(.detail))
        _ = await store.perform(.openWindow(.init(id: windowID, route: .home)))
        _ = await store.perform(.enterImmersiveSpace(.init(id: immersiveID, route: .home)))
        #expect(root === store.scope())
        #expect(left === store.scope(at: ["left"]))
        #expect(right === store.scope(at: ["right"]))
        #expect(root.sceneLifetime == nil)
        #expect(left.sceneLifetime == nil)
        #expect(right.sceneLifetime == nil)
        #expect(root.reconciliationRevision == 0)
        #expect(left.reconciliationRevision == 0)
        #expect(right.reconciliationRevision == 0)
    }
}
