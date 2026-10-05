import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Enclosing presentation authority", .timeLimit(.minutes(1)))
@MainActor
struct RouterEnclosingPresentationEndpointTests {
    private enum R: Route { case home, outer, inner, detail }
    private enum Leaf: Route { case screen, detail }
    private enum Feature: Route { case leaf(Leaf) }
    private enum App: Route { case home, feature(Feature) }

    private var featureMapping: RouterFeatureMapping<App, Feature> {
        .init(id: "feature", namespace: "feature", route: .init(embed: App.feature, extract: {
            guard case .feature(let value) = $0 else { return nil }; return value
        }))
    }

    private var leafMapping: RouterFeatureMapping<Feature, Leaf> {
        .init(id: "leaf", namespace: "leaf", route: .init(embed: Feature.leaf, extract: {
            guard case .leaf(let value) = $0 else { return nil }; return value
        }))
    }

    private func endpoint<RouteType: Route>(
        _ store: RouterStore<RouteType>,
        at owner: RouterScopePath = .root,
        child: RouterScopePath? = nil
    ) throws -> RouterEnclosingPresentationEndpoint<RouteType> {
        let handle = try #require(store.presentationHandle(at: owner))
        return .init(owner: store.scope(at: owner),
                     renderedChild: store.scope(at: child ?? owner.appendingPresentation(handle.id)),
                     handle: handle)
    }

    private func open<RouteType: Route>(
        _ presentation: RouterPresentation<RouteType>,
        in store: RouterStore<RouteType>, at path: RouterScopePath = .root
    ) async -> Task<RouterPresentationOutcome<String>, Never> {
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in
            await store.awaitPresentation(
                .present(presentation), id: presentation.id, at: path, expecting: String.self,
                selectionActions: nil, executionPrecondition: nil, requestSemantics: .action
            )
        }
        while let event = await events.next() { if case .committed = event { break } }
        return result
    }

    private func expired(_ outcome: RouterOutcome<R>, handle: RouterPresentationHandle) {
        guard case .rejected(_, _, _, .mutation(.expiredPresentation(let id, let path))) = outcome else {
            Issue.record("Expected captured presentation to expire"); return
        }
        #expect(id == handle.id)
        #expect(path == handle.scope)
    }

    @Test("Navigation targets the child while enclosing detents and dismissal target the owner")
    func childNavigationAndOwnerActions() async throws {
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet,
                                                options: .init(detents: [.medium, .large], selectedDetent: .medium))
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(path: [.home], presentation: presentation)))
        let path = RouterScopePath.root.appendingPresentation(presentation.id)
        let child = store.scope(at: path)
        let enclosing = try endpoint(store)
        _ = await child.perform(.push(.detail))
        #expect(store.state.node(at: path) == .stack(path: [.detail]))
        #expect(store.scope().observedPath == [.home])
        _ = await child.perform(.pop(count: 1))
        guard case .applied = await enclosing.setPresentationDetent(.large) else {
            Issue.record("The enclosing owner must receive detent changes"); return
        }
        #expect(store.scope().observedPresentation?.options.selectedDetent == .large)
        let before = store.state
        guard case .applied(_, let reportedBefore, let after, let revision) = await enclosing.dismiss() else {
            Issue.record("The enclosing owner must dismiss"); return
        }
        #expect(reportedBefore == before)
        #expect(after == .rootStack(path: [.home]))
        #expect(revision == store.revision)
        #expect(child.node == nil)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Nested modal completion returns only to the nearest captured waiter")
    func nestedOwnerIsolation() async throws {
        let store = try RouterStore<R>(initialPath: [.home])
        let outer = RouterPresentation<R>(route: .outer, style: .sheet)
        let outerResult = await open(outer, in: store)
        defer { outerResult.cancel() }
        let outerEndpoint = try endpoint(store)
        let childPath = RouterScopePath.root.appendingPresentation(outer.id)
        let inner = RouterPresentation<R>(route: .inner, style: .sheet)
        let innerResult = await open(inner, in: store, at: childPath)
        defer { innerResult.cancel() }
        let innerEndpoint = try endpoint(store, at: childPath)
        try await innerEndpoint.finishPresentation(.init(route: .inner), returning: "inner-result")
        #expect(await innerResult.value == .value("inner-result"))
        #expect(Set(store.presentationWaiters.keys) == [outer.id])
        #expect(store.scope().observedPresentation?.id == outer.id)
        #expect(store.state.node(at: childPath) == .stack())
        try await outerEndpoint.finishPresentation(.init(route: .outer), returning: "outer-result")
        #expect(await outerResult.value == .value("outer-result"))
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("A callback cannot use an outer handle from inside a nearer modal")
    func invalidAncestryAndStore() async throws {
        let inner = RouterPresentation<R>(route: .inner, style: .sheet)
        let outer = RouterPresentation<R>(route: .outer, style: .sheet, node: .stack(presentation: inner))
        let store = try RouterStore(initialState: RouterState(root: .stack(presentation: outer)))
        let handle = try #require(store.presentationHandle())
        let innerPath = RouterScopePath.root.appendingPresentation(outer.id).appendingPresentation(inner.id)
        let wrong = RouterEnclosingPresentationEndpoint(owner: store.scope(), renderedChild: store.scope(at: innerPath), handle: handle)
        guard case .rejected = await wrong.dismiss() else { Issue.record("Must preserve nearest-owner isolation"); return }
        let otherStore = try RouterStore(initialState: store.state)
        let wrongStore = RouterEnclosingPresentationEndpoint(owner: store.scope(), renderedChild: otherStore.scope(at: innerPath), handle: handle)
        guard case .rejected = await wrongStore.dismiss() else { Issue.record("Cross-store capture must reject"); return }
        #expect(store.revision == 0)
        #expect(otherStore.revision == 0)
        #expect(store.presentationLifetimes.count == 2)
    }

    @Test("Same-ID replacement rejects stale dismiss detent and typed finish before waiter lookup")
    func replacedPresentation() async throws {
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet,
                                                options: .init(detents: [.medium, .large]))
        let state = try RouterState<R>(root: .stack(presentation: presentation))
        var policies = 0
        let store = try RouterStore(initialState: state, configuration: .init(policies: [
            .init(name: "count") { _ in policies += 1; return .allow },
        ]))
        let old = try endpoint(store), handle = try #require(store.presentationHandle())
        _ = await store.replaceSubtree(at: .root.appendingPresentation(presentation.id), with: .stack())
        policies = 0
        expired(await old.dismiss(), handle: handle)
        expired(await old.setPresentationDetent(.large), handle: handle)
        await #expect(throws: RouterPresentationCompletionError.dismissalRejected(.mutation(.expiredPresentation(handle.id, scope: .root)))) {
            // Deliberately mismatched route and no waiter: lifetime wins first.
            try await old.finishPresentation(.init(route: .inner), returning: 1)
        }
        #expect(policies == 0)
        #expect(store.state == state)
        #expect(store.revision == 0)
        #expect(store.presentationHandle() != handle)
        guard case .applied = try await endpoint(store).dismiss() else { Issue.record("Fresh control must dismiss"); return }
    }

    @Test("Removed rendered branch rejects before an active owner's result is prepared")
    func removedRenderedChild() async throws {
        let tabs = RouterNode<R>.container(try .init(style: .tabs, selection: "left", branches: [
            .init(id: "left", node: .stack(path: [.detail])), .init(id: "right"),
        ]))
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet, node: tabs)
        let store = RouterStore<R>()
        let result = await open(presentation, in: store)
        defer { result.cancel() }
        let root = RouterScopePath.root.appendingPresentation(presentation.id)
        let old = try endpoint(store, child: root.appending("left"))
        let handle = try #require(store.presentationHandle())
        let replacement = RouterNode<R>.container(try .init(style: .tabs, selection: "right", branches: [.init(id: "right")]))
        let next = try store.state.replacingNode(replacement, at: root)
        _ = await store.perform(.apply(.init(state: next)))
        #expect(store.presentationHandle() == handle)
        #expect(store.presentationWaiters.count == 1)
        await #expect(throws: RouterPresentationCompletionError.dismissalRejected(.mutation(.expiredScope(root.appending("left"))))) {
            // Wrong result type would fail earlier if this touched the waiter.
            try await old.finishPresentation(returning: 42)
        }
        #expect(store.presentationWaiters.count == 1)
        try await endpoint(store, child: root.appending("right")).finishPresentation(returning: "live-branch")
        #expect(await result.value == .value("live-branch"))
        #expect(store.state == .rootStack)
    }

    @Test("Nested feature completion projects only the rendered child and embeds the exact request")
    func nestedFeatureFinish() async throws {
        let store = try RouterStore<App>(initialPath: [.home])
        let presentation = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet,
                                                  node: .stack(path: [.feature(.leaf(.detail))]))
        let result = await open(presentation, in: store)
        defer { result.cancel() }
        let enclosing = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        // This owner is intentionally not projectable as a feature scope.
        #expect(RouterFeatureScope(parent: store.scope(), mapping: featureMapping).node == nil)
        await #expect(throws: RouterPresentationCompletionError.presentationRouteMismatch(presentation.id)) {
            try await enclosing.finishPresentation(.init(route: .detail), returning: "wrong-route")
        }
        #expect(store.presentationWaiters.count == 1)
        try await enclosing.finishPresentation(.init(route: .screen), returning: "feature-result")
        #expect(await result.value == .value("feature-result"))
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 2)
    }

    @Test("Nested feature wrappers retain the nearest nested modal completion target")
    func nestedFeatureOwnerIsolation() async throws {
        let store = try RouterStore<App>(initialPath: [.home])
        let outer = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet)
        let outerResult = await open(outer, in: store)
        defer { outerResult.cancel() }
        let outerEndpoint = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        let outerChild = RouterScopePath.root.appendingPresentation(outer.id)
        let inner = RouterPresentation<App>(route: .feature(.leaf(.detail)), style: .sheet)
        let innerResult = await open(inner, in: store, at: outerChild)
        defer { innerResult.cancel() }
        let innerEndpoint = try endpoint(store, at: outerChild).projected(using: featureMapping).projected(using: leafMapping)
        try await innerEndpoint.finishPresentation(.init(route: .detail), returning: "inner-feature")
        #expect(await innerResult.value == .value("inner-feature"))
        #expect(Set(store.presentationWaiters.keys) == [outer.id])
        #expect(outerEndpoint.isCurrent)
        #expect(!innerEndpoint.isCurrent)
        try await outerEndpoint.finishPresentation(.init(route: .screen), returning: "outer-feature")
        #expect(await outerResult.value == .value("outer-feature"))
        #expect(store.state == .rootStack(path: [.home]))
    }

    @Test("An expired presenting scope cannot borrow a fresh handle for typed completion")
    func staleOwnerFreshHandle() async throws {
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet)
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(presentation: presentation)))
        let oldOwner = store.scope()
        _ = await store.replaceSubtree(with: store.state.root)
        let freshHandle = try #require(store.presentationHandle())
        let mixed = RouterEnclosingPresentationEndpoint(
            owner: oldOwner, renderedChild: store.scope(at: .root.appendingPresentation(presentation.id)),
            handle: freshHandle
        )
        #expect(!mixed.isCurrent)
        await #expect(throws: RouterPresentationCompletionError.dismissalRejected(.mutation(.expiredScope(.root)))) {
            try await mixed.finishPresentation(.init(route: .inner), returning: 42)
        }
        #expect(store.revision == 0)
    }

    @Test("Successful feature dismissal reports an applied removed-child projection")
    func featureDismissalProjection() async throws {
        let presentation = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet,
                                                  node: .stack(path: [.feature(.leaf(.detail))]))
        let store = try RouterStore(initialState: RouterState<App>(root: .stack(path: [.home], presentation: presentation)))
        let enclosing = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        var events = store.events.makeAsyncIterator()
        guard case .applied(let id, let before, let after, let revision) = await enclosing.dismiss() else {
            Issue.record("A committed dismissal must not become a featureProjection rejection"); return
        }
        #expect(before == .rootStack(path: [.detail]))
        #expect(after == .rootStack)
        #expect(revision == 1)
        #expect(store.state == .rootStack(path: [.home]))
        while let event = await events.next() {
            if case .committed(let committedID, _, _, _, _) = event {
                #expect(committedID == id)
                break
            }
        }
    }

    @Test("A lost feature projection rejects before result type checking")
    func featureProjectionLoss() async throws {
        let store = try RouterStore<App>(initialPath: [.home])
        let presentation = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet,
                                                  node: .stack(path: [.feature(.leaf(.detail))]))
        let result = await open(presentation, in: store)
        defer { result.cancel() }
        let childPath = RouterScopePath.root.appendingPresentation(presentation.id)
        let enclosing = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        let handle = try #require(store.presentationHandle())
        _ = await store.scope(at: childPath).perform(.replaceStack([.home]))
        #expect(store.presentationHandle() == handle)
        await #expect(throws: RouterPresentationCompletionError.dismissalRejected(.featureProjection(.routeMismatch(namespace: "feature")))) {
            try await enclosing.finishPresentation(returning: 42)
        }
        #expect(store.presentationWaiters.count == 1)
        #expect(store.revision == 2)
        _ = try await endpoint(store).dismiss()
        #expect(await result.value == .dismissed)
    }

    @Test("Feature unchanged rejected and deferred outcomes retain child snapshots and identifiers")
    func featureNonterminalOutcomes() async throws {
        let deferral = RouterDeferralID()
        let presentation = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet,
                                                  options: .init(detents: [.medium, .large], selectedDetent: .medium),
                                                  node: .stack(path: [.feature(.leaf(.detail))]))
        let store = try RouterStore(initialState: RouterState<App>(root: .stack(path: [.home], presentation: presentation)),
                                    configuration: .init(policies: [
            .init(name: "hold-dismiss") { transition in
                if case .dismissPresentation = transition.action, transition.context.resumedDeferral == nil {
                    return .deferRequest(deferral)
                }
                return .allow
            },
        ]))
        let enclosing = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        guard case .unchanged(_, let unchanged, let revision) = await enclosing.setPresentationDetent(.medium) else {
            Issue.record("Expected unchanged detent"); return
        }
        #expect(unchanged == .rootStack(path: [.detail]))
        #expect(revision == 0)
        guard case .rejected(_, let rejected, let rejectedRevision, _) = await enclosing.setPresentationDetent(.height(123)) else {
            Issue.record("Expected undeclared-detent rejection"); return
        }
        #expect(rejected == unchanged)
        #expect(rejectedRevision == revision)
        guard case .deferred(let id, let projected, let deferredRevision, let descriptor) = await enclosing.dismiss() else {
            Issue.record("Expected deferred dismissal"); return
        }
        #expect(projected == unchanged)
        #expect(deferredRevision == 0)
        #expect(descriptor.id == deferral)
        #expect(store.deferredTransitions.first?.transitionID == id)
        guard case .applied = await store.resumeDeferred(deferral) else { Issue.record("Valid capture must resume"); return }
        #expect(store.state == .rootStack(path: [.home]))
    }

    @Test("Queued enclosing callbacks retain captured authority across same-ID replacement")
    func queuedCallback() async throws {
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        let (queued, enqueue) = AsyncStream<Void>.makeStream()
        defer { enter.finish(); resume.finish(); enqueue.finish() }
        var responsePolicies = 0
        var configuration = RouterStoreConfiguration<R>(policies: [
            .init(name: "hold-replacement") { transition in
                if case .apply = transition.action {
                    enter.yield(())
                    for await _ in release { break }
                } else { responsePolicies += 1 }
                return .allow
            },
        ])
        configuration.runtimeDependencies.didQueueRequest = { _ in enqueue.yield(()) }
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet)
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(presentation: presentation)), configuration: configuration)
        let old = try endpoint(store), handle = try #require(store.presentationHandle())
        let replacement = Task { @MainActor in
            await store.replaceSubtree(at: .root.appendingPresentation(presentation.id), with: .stack())
        }
        var entry = entered.makeAsyncIterator(); _ = await entry.next()
        let callback = Task { @MainActor in await old.dismiss() }
        var queue = queued.makeAsyncIterator(); _ = await queue.next()
        resume.yield(())
        _ = await replacement.value
        expired(await callback.value, handle: handle)
        #expect(responsePolicies == 0)
        #expect(store.revision == 0)
        #expect(store.presentationHandle() != handle)
    }

    @Test("Deferred enclosing completion keeps its capture until actual resumption")
    func deferredCallback() async throws {
        let deferral = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold-dismiss") { transition in
                if case .dismissPresentation = transition.action, transition.context.resumedDeferral == nil {
                    return .deferRequest(deferral)
                }
                return .allow
            },
        ]))
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet)
        let result = await open(presentation, in: store)
        defer { result.cancel() }
        let old = try endpoint(store), handle = try #require(store.presentationHandle())
        await #expect(throws: RouterPresentationCompletionError.dismissalDeferred(deferral)) {
            try await old.finishPresentation(returning: "held-result")
        }
        #expect(store.presentationWaiters.count == 1)
        _ = await store.replaceSubtree(at: .root.appendingPresentation(presentation.id), with: .stack())
        #expect(await result.value == .cancelled)
        expired(await store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState), handle: handle)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.scope().observedPresentation?.id == presentation.id)
    }

    @MainActor
    private final class ObservationCount { var value = 0 }

    @Test("Endpoint validity observes incarnation changes without depending on child path edits")
    func observableValidity() async throws {
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet)
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(presentation: presentation)))
        let enclosing = try endpoint(store), count = ObservationCount()
        let path = RouterScopePath.root.appendingPresentation(presentation.id)
        #expect(enclosing.isCurrent)
        withObservationTracking { _ = enclosing.isCurrent } onChange: {
            MainActor.assumeIsolated { count.value += 1 }
        }
        _ = await store.scope(at: path).perform(.push(.detail))
        #expect(count.value == 0)
        #expect(enclosing.isCurrent)
        _ = await store.replaceSubtree(at: path, with: .stack(path: [.detail]))
        #expect(count.value == 1)
        #expect(!enclosing.isCurrent)
        #expect(try endpoint(store).isCurrent)
    }

    @Test("Mapped endpoint validity observes loss of only its rendered feature projection")
    func observableFeatureValidity() async throws {
        let presentation = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet,
                                                  node: .stack(path: [.feature(.leaf(.detail))]))
        let store = try RouterStore(initialState: RouterState<App>(root: .stack(path: [.home], presentation: presentation)))
        let enclosing = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        let count = ObservationCount()
        #expect(enclosing.isCurrent)
        withObservationTracking { _ = enclosing.isCurrent } onChange: {
            MainActor.assumeIsolated { count.value += 1 }
        }
        _ = await store.scope(at: .root.appendingPresentation(presentation.id)).perform(.replaceStack([.home]))
        #expect(count.value == 1)
        #expect(!enclosing.isCurrent)
        #expect(try endpoint(store).isCurrent)
    }

    @Test("A rejected lost feature retains the original rejection and Store revision")
    func rejectedProjectionLoss() async throws {
        let presentation = RouterPresentation<App>(route: .feature(.leaf(.screen)), style: .sheet,
                                                  node: .stack(path: [.feature(.leaf(.detail))]))
        let store = try RouterStore(initialState: RouterState<App>(root: .stack(path: [.home], presentation: presentation)))
        let enclosing = try endpoint(store).projected(using: featureMapping).projected(using: leafMapping)
        _ = await store.scope(at: .root.appendingPresentation(presentation.id)).perform(.replaceStack([.home]))
        let before = store.state, revision = store.revision
        guard case .rejected(_, let projected, let rejectedRevision, .featureProjection) = await enclosing.dismiss() else {
            Issue.record("Projection loss was not rejected"); return
        }
        #expect(projected == .rootStack)
        #expect(rejectedRevision == revision)
        #expect(store.state == before)
        #expect(store.revision == revision)
        #expect(store.presentationHandle() != nil)
    }
}
