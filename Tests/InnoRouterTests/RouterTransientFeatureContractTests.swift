import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Transient feature authority", .timeLimit(.minutes(1)))
@MainActor
struct RouterTransientFeatureContractTests {
    private enum Child: Route { case home }
    private enum Parent: Route { case feature(Child), other }
    private enum Root: Route { case parent(Parent) }

    private var childMapping: RouterFeatureMapping<Parent, Child> {
        .init(id: "feature", namespace: "feature", route: .init(embed: Parent.feature, extract: {
            guard case .feature(let child) = $0 else { return nil }
            return child
        }))
    }

    private func request() -> RouterTransientPresentationRequest<Int> {
        .confirmationDialog(title: "Title", actions: [.init(id: "accept", label: "Accept", value: 42)])
    }

    @Test("Nested feature requests keep one authority and route-independent typed values")
    func nestedFeatureSelection() async throws {
        let store = try RouterStore<Root>(initialPath: [.parent(.feature(.home))])
        let outerMapping = RouterFeatureMapping<Root, Parent>(id: "outer", namespace: "outer", route: .init(embed: Root.parent, extract: {
            guard case .parent(let value) = $0 else { return nil }
            return value
        }))
        let outer = RouterFeatureScope(parent: store.scope(), mapping: outerMapping)
        let feature = RouterFeatureScope(parent: outer as any RouterAuthorityProtocol<Parent>, mapping: childMapping)
        var events = store.events.makeAsyncIterator()
        var observations = store.requestObservations.makeAsyncIterator()
        let result = Task { @MainActor in await feature.present(request()) }
        while let event = await events.next() { if case .committed = event { break } }
        let handle = try #require(feature.presentationHandle())
        #expect(feature.presentationFamily?.kind == .confirmationDialog)
        let observation = try #require(await observations.next())
        guard case .featureAction(_, _, let features) = observation.semantics else { Issue.record("Missing feature ownership"); result.cancel(); return }
        #expect(features.map(\.namespace) == ["outer", "feature"])
        #expect(observation.replayLimitationCode == "presentation.runtimeResultAuthority")
        guard case .applied = await feature.selectPresentationAction("accept", using: handle) else {
            Issue.record("Expected one accepted selection"); result.cancel(); return
        }
        #expect(await result.value == .value(42))
        #expect(store.state == .rootStack(path: [.parent(.feature(.home))]))
        #expect(store.revision == 2)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("The original feature projection remains required for result delivery")
    func removedFeatureProjection() async throws {
        let policyCalls = Mutex(0)
        let store = try RouterStore<Parent>(initialPath: [.feature(.home)], configuration: .init(policies: [
            .init(name: "count") { _ in policyCalls.withLock { $0 += 1 }; return .allow },
        ]))
        let feature = RouterFeatureScope(parent: store.scope(), mapping: childMapping)
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await feature.present(request()) }
        while let event = await events.next() { if case .committed = event { break } }
        let handle = try #require(feature.presentationHandle())
        let family = try #require(feature.presentationFamily)
        let parentFamily: RouterPresentationFamily<Parent>
        guard case .confirmationDialog(let descriptor) = family else { Issue.record("Missing dialog"); result.cancel(); return }
        parentFamily = .confirmationDialog(descriptor)
        let replacement = try RouterState<Parent>(root: .stack(path: [.other], presentationFamily: parentFamily))
        _ = await store.perform(.apply(.init(state: replacement)))
        #expect(feature.node == nil)
        policyCalls.withLock { $0 = 0 }
        let revision = store.revision
        guard case .rejected(_, _, _, .featureProjection(.routeMismatch(namespace: "feature"))) = await store.selectPresentationAction("accept", using: handle) else {
            Issue.record("Original feature authority was lost"); result.cancel(); return
        }
        #expect(store.state == replacement)
        #expect(store.revision == revision)
        #expect(policyCalls.withLock { $0 } == 0)
        #expect(store.presentationWaiters.count == 1)
        _ = await store.dismissPresentation(using: handle)
        #expect(await result.value == .dismissed)
    }

    @Test("A scope cannot use another owner's handle to dismiss its own or another presentation")
    func crossScopeHandle() async throws {
        let store = try RouterStore<Child>(initialState: .init(root: .container(.init(style: .tabs, selection: "left", branches: [
            .init(id: "left"), .init(id: "right"),
        ]))))
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await left.present(request()) }
        while let event = await events.next() { if case .committed = event { break } }
        let handle = try #require(left.presentationHandle()), original = store.state
        guard case .rejected = await right.dismissPresentation(using: handle) else { Issue.record("Cross-scope handle accepted"); result.cancel(); return }
        #expect(store.state == original)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.count == 1)
        _ = await left.dismissPresentation(using: handle)
        #expect(await result.value == .dismissed)
    }
}
