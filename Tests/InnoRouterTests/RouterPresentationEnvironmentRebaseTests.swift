import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Recursive presentation environment authority", .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationEnvironmentRebaseTests {
    private enum Child: Route { case home, detail }
    private indirect enum R: Route { case layer(R), feature(Child), other }
    private enum Other: Route { case detail }

    private var layer: RouterFeatureMapping<R, R> {
        .init(id: "layer", namespace: "layer", route: .init(embed: R.layer, extract: {
            guard case .layer(let value) = $0 else { return nil }; return value
        }))
    }
    private var child: RouterFeatureMapping<R, Child> {
        .init(id: "feature", namespace: "feature", route: .init(embed: R.feature, extract: {
            guard case .feature(let value) = $0 else { return nil }; return value
        }))
    }

    @Test("Rebasing finite repeated-type feature chains changes navigation but retains nearest completion authority")
    func inheritedFeatureRebase() async throws {
        let store = try RouterStore<R>(initialPath: [.other]), unrelated = RouterStore<Other>()
        let owner = store.scope()
        let outer = RouterFeatureScope(parent: owner, mapping: layer)
        let feature = RouterFeatureScope(parent: outer as any RouterAuthorityProtocol<R>, mapping: child)
        var environment = RouterEnvironment()
        environment[R.self] = .init(base: outer)
        environment[Child.self] = .init(base: feature)
        environment[Other.self] = .init(scope: unrelated.scope())
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await store.present(.layer(.feature(.home)), expecting: String.self) }
        defer { result.cancel() }
        while let event = await events.next() { if case .committed = event { break } }
        let handle = try #require(store.presentationHandle())
        let rendered = store.scope(at: .root.appendingPresentation(handle.id))
        let endpoint = RouterEnclosingPresentationEndpoint(owner: owner, renderedChild: rendered, handle: handle)
        environment.rebase(replacing: owner, with: .init(scope: rendered, enclosingPresentation: endpoint))
        #expect(environment[R.self]?.base === rendered)
        let projected = try #require(environment[Child.self])
        let actions = RouterActions(routeType: Child.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
        let reader = RouterStateReader(authority: projected.base, enclosingPresentation: projected.enclosingPresentation)
        #expect(reader.canDismissPresentation)
        #expect(reader.presentationFamily == nil)
        _ = await actions.go(.detail).value
        #expect(rendered.observedPath == [.layer(.feature(.detail))])
        #expect(owner.observedPath == [.other])
        #expect(feature.node == nil)
        let otherActions = RouterActions(routeType: Other.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
        _ = await otherActions.go(.detail).value
        #expect(unrelated.state == .rootStack(path: [.detail]))
        try await actions.finishPresentation(RouterPresentationRequest(route: .home), returning: "done")
        #expect(await result.value == .value("done"))
        #expect(store.state == .rootStack(path: [.other]))
        #expect(!reader.canDismissPresentation)
    }

    @Test("Explicit actions target the child while facade dismissal targets its enclosing modal")
    func explicitChildAction() async throws {
        let store = RouterStore<R>(), owner = store.scope()
        _ = await store.perform(.present(.init(route: .other, style: .sheet)))
        let handle = try #require(store.presentationHandle())
        let rendered = store.scope(at: .root.appendingPresentation(handle.id))
        let endpoint = RouterEnclosingPresentationEndpoint(owner: owner, renderedChild: rendered, handle: handle)
        let actions = RouterActions(authority: .init(scope: rendered, enclosingPresentation: endpoint))
        _ = await actions.go(.other).value
        #expect(rendered.observedPath == [.other])
        guard case .unchanged = await actions.perform(.dismissPresentation) else { Issue.record("An explicit empty-child dismissal changed ownership"); return }
        #expect(store.presentationHandle() == handle)
        guard case .applied = await actions.dismiss().value else { Issue.record("Enclosing dismissal was not applied"); return }
        #expect(store.state == .rootStack)
    }

    @Test("An expired facade cannot finish a new same-ID incarnation")
    func oldFacade() async throws {
        let store = RouterStore<R>(), owner = store.scope()
        _ = await store.perform(.present(.init(route: .other, style: .sheet)))
        let handle = try #require(store.presentationHandle())
        let rendered = store.scope(at: .root.appendingPresentation(handle.id))
        let actions = RouterActions(authority: .init(scope: rendered, enclosingPresentation: .init(owner: owner, renderedChild: rendered, handle: handle)))
        _ = await store.replaceSubtree(at: rendered.path, with: .stack())
        guard case .rejected = await actions.dismiss().value else { Issue.record("Old facade dismissed replacement"); return }
        #expect(store.presentationHandle() != nil)
    }
    @Test("Nested modal rebasing preserves old outer authority and expires only the closed inner facade")
    func nestedRebase() async throws {
        let store = RouterStore<R>(), owner = store.scope()
        _ = await store.perform(.present(.init(route: .other, style: .sheet)))
        let outer = try #require(store.presentationHandle())
        let outerChild = store.scope(at: .root.appendingPresentation(outer.id))
        var environment = RouterEnvironment()
        environment[R.self] = .init(scope: owner)
        environment.rebase(replacing: owner, with: .init(scope: outerChild, enclosingPresentation: .init(owner: owner, renderedChild: outerChild, handle: outer)))
        let old = RouterActions(routeType: R.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await old.present(R.other, expecting: String.self) }
        defer { result.cancel() }
        while let event = await events.next() { if case .committed = event { break } }
        let inner = try #require(outerChild.presentationHandle())
        let innerChild = store.scope(at: outerChild.path.appendingPresentation(inner.id))
        environment.rebase(replacing: outerChild, with: .init(scope: innerChild, enclosingPresentation: .init(owner: outerChild, renderedChild: innerChild, handle: inner)))
        let latest = RouterActions(routeType: R.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
        try await latest.finishPresentation(returning: "inner")
        #expect(await result.value == .value("inner"))
        #expect(store.presentationHandle() == outer)
        guard case .rejected = await latest.dismiss().value else { Issue.record("Closed inner facade acquired outer authority"); return }
        guard case .applied = await old.dismiss().value else { Issue.record("Outer authority expired after inner completion"); return }
        #expect(store.state == .rootStack)
    }

    @Test("A willSet observer can capture and rebase a fresh endpoint from the installed registries")
    func synchronousFreshCapture() async throws {
        let store = RouterStore<R>(), owner = store.scope()
        _ = await store.perform(.present(.init(route: .other, style: .sheet)))
        let original = try #require(store.presentationHandle())
        let childPath = RouterScopePath.root.appendingPresentation(original.id)
        let capture = Capture()
        withObservationTracking { _ = store.presentationHandle() } onChange: {
            MainActor.assumeIsolated {
                guard let handle = store.presentationHandle() else { return }
                let child = store.scope(at: childPath)
                var environment = RouterEnvironment()
                environment[R.self] = .init(scope: owner)
                environment.rebase(replacing: owner, with: .init(scope: child, enclosingPresentation: .init(owner: owner, renderedChild: child, handle: handle)))
                capture.actions = RouterActions(routeType: R.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
                capture.handle = handle
            }
        }
        _ = await store.replaceSubtree(at: childPath, with: .stack())
        #expect(capture.handle != original)
        let actions = try #require(capture.actions)
        _ = await actions.go(.other).value
        #expect(store.scope(at: childPath).observedPath == [.other])
        guard case .applied = await actions.dismiss().value else { Issue.record("Fresh captured endpoint was stale"); return }
        #expect(store.state == .rootStack)
    }

    @MainActor private final class Capture {
        var actions: RouterActions<R>?
        var handle: RouterPresentationHandle?
    }
}
