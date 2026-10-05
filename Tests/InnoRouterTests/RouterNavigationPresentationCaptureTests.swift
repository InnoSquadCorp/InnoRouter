import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Recursive native presentation capture contracts", .timeLimit(.minutes(1)))
@MainActor
struct RouterNavigationPresentationCaptureTests {
    private enum Leaf: Route { case home, detail }
    private enum R: Route { case outer, inner, detail, feature(Leaf) }

    private var mapping: RouterFeatureMapping<R, Leaf> {
        .init(id: "feature", namespace: "feature", route: .init(embed: R.feature, extract: {
            guard case .feature(let route) = $0 else { return nil }; return route
        }))
    }

    private func store(child: RouterNode<R> = .stack()) throws -> RouterStore<R> {
        try RouterStore(initialState: RouterState(root: .stack(path: [.detail], presentation: .init(
            route: .outer, style: .sheet, node: child
        ))))
    }

    private func dismiss(_ capture: RouterNavigationPresentationCapture<R>) async -> RouterOutcome<R> {
        await capture.owner.perform(.dismissPresentation, context: .init(source: .system),
                                    expectedRevision: nil, executionPrecondition: capture.executionPrecondition)
    }

    @Test("Capture identifies and navigates the real canonical child without another Store")
    func actualChild() async throws {
        let store = try store(child: .stack(path: [.inner]))
        let capture = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
        #expect(capture.id == store.presentationHandle())
        #expect(capture.owner.store === store)
        #expect(capture.child.store === store)
        #expect(capture.child === store.scope(at: capture.child.path))
        #expect(capture.child.observedPath == [.inner])
        _ = await capture.child.perform(.push(.detail))
        #expect(store.scope().observedPath == [.detail])
        #expect(capture.child.observedPath == [.inner, .detail])
        #expect(capture.isCurrent)
        guard case .applied = await dismiss(capture) else { Issue.record("Captured dismissal did not apply"); return }
        #expect(store.state == .rootStack(path: [.detail]))
        #expect(!capture.isCurrent)
    }

    @Test("Same-ID child-root and owner restoration retire capture identity and all callbacks")
    func replacementIdentity() async throws {
        for ownerReplacement in [false, true] {
            let store = try store()
            let old = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
            if ownerReplacement { _ = await store.replaceSubtree(with: store.state.root) }
            else { _ = await store.replaceSubtree(at: old.child.path, with: .stack()) }
            let fresh = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
            #expect(old.handle.id == fresh.handle.id)
            #expect(old.id != fresh.id)
            #expect(old.child !== fresh.child)
            #expect(old.presentation == nil)
            guard case .rejected = await dismiss(old) else { Issue.record("Stale native callback acquired replacement"); continue }
            #expect(fresh.isCurrent)
            guard case .applied = await dismiss(fresh) else { Issue.record("Fresh native callback was stale"); continue }
            #expect(store.state == .rootStack(path: [.detail]))
        }
    }

    @Test("willSet can capture the newly installed same-ID child incarnation")
    func freshWillSetCapture() async throws {
        let store = try store()
        let owner = store.scope()
        let old = try #require(RouterNavigationPresentationCapture(owner: owner))
        let result = CaptureBox()
        withObservationTracking { _ = owner.presentationHandle() } onChange: {
            MainActor.assumeIsolated { result.value = RouterNavigationPresentationCapture(owner: owner) }
        }
        _ = await store.replaceSubtree(at: old.child.path, with: .stack())
        let fresh = try #require(result.value)
        #expect(fresh.isCurrent)
        #expect(fresh.id != old.id)
        #expect(fresh.child === store.scope(at: old.child.path))
        guard case .applied = await dismiss(fresh) else { Issue.record("willSet capture retained old authority"); return }
    }

    @Test("Each descendant rebases feature navigation and completion onto the exact branch")
    func featureBranchRebase() async throws {
        let tabs = RouterNode<R>.container(try .init(style: .tabs, selection: "home", branches: [
            .init(id: "home"), .init(id: "other"),
        ]))
        let store = try store(child: tabs)
        let capture = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
        var environment = RouterEnvironment()
        environment[R.self] = .init(scope: capture.owner)
        environment[Leaf.self] = .init(base: RouterFeatureScope(parent: capture.owner, mapping: mapping))
        let initial = RouterNavigationPresentationRenderContext(capture: capture)
        environment = try #require(initial.rebase(environment, onto: capture.child))
        let rootContext = try #require(initial.scoped(to: capture.child))
        let branch = store.scope(at: capture.child.path.appending("home"))
        environment = try #require(rootContext.rebase(environment, onto: branch))
        let actions = RouterActions(routeType: Leaf.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
        _ = await actions.go(.detail).value
        #expect(branch.observedPath == [.feature(.detail)])
        #expect(store.scope().observedPath == [.detail])
        #expect(store.scope(at: capture.child.path.appending("other")).observedPath == [])
        guard case .applied = await actions.dismiss().value else { Issue.record("Descendant lost its enclosing endpoint"); return }
        #expect(store.state == .rootStack(path: [.detail]))
    }

    @Test("Context cannot cross a Store or a nearer presentation boundary")
    func nearestBoundary() async throws {
        let store = try store(child: .stack(presentation: .init(route: .inner, style: .sheet)))
        let outer = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
        let inner = try #require(RouterNavigationPresentationCapture(owner: outer.child))
        let unrelated = try self.store()
        #expect(!outer.contains(inner.child))
        #expect(!outer.contains(unrelated.scope(at: outer.child.path)))
        #expect(outer.enclosingEndpoint(for: inner.child) == nil)
        var environment = RouterEnvironment()
        environment[R.self] = .init(scope: outer.child, enclosingPresentation: outer.enclosingEndpoint(for: outer.child))
        environment = try #require(RouterNavigationPresentationRenderContext(capture: inner).rebase(environment, onto: inner.child))
        let actions = RouterActions(routeType: R.self, environmentMissingPolicy: .logAndDegrade, environment: environment)
        guard case .applied = await actions.dismiss().value else { Issue.record("Inner dismissal did not apply"); return }
        #expect(outer.isCurrent)
        #expect(!inner.isCurrent)
        #expect(store.presentationHandle() == outer.handle)
    }

    @Test("Retaining a removed branch cannot dismiss its surviving enclosing modal")
    func removedBranch() async throws {
        let node = RouterNode<R>.container(try .init(style: .tabs, selection: "home", branches: [.init(id: "home"), .init(id: "other")]))
        let store = try store(child: node)
        let capture = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
        let branch = store.scope(at: capture.child.path.appending("home"))
        let endpoint = try #require(capture.enclosingEndpoint(for: branch))
        _ = await store.replaceSubtree(at: branch.path, with: .stack())
        #expect(capture.isCurrent)
        #expect(!capture.contains(branch))
        guard case .rejected = await endpoint.dismiss() else { Issue.record("Removed branch retained completion authority"); return }
        #expect(store.presentationHandle() == capture.handle)
    }

    @Test("Configured non-stack catalog, root meanings, and native capture share one admitted child")
    func configuredCatalogCapture() async throws {
        let shape = RouterHostShape.tabs(branches: [
            .init("home", shape: .stack), .init("other", shape: .stack),
        ], extras: .reject)
        let roots: [RouterHostRootDeclaration<R>] = [
            .init(path: ["home"], meaning: .route(.feature(.home))),
            .init(path: ["other"], meaning: .declarationID("other-root")),
        ]
        let descriptor = RouterHostDescriptor<R>(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))],
            presentations: .init(entries: [.init("composer", shape: shape, rootDeclarations: roots)],
                                 declaration: { $0 == .outer ? "composer" : nil })
        )
        let node = RouterNode<R>.container(try .init(style: .tabs, selection: "home", branches: [
            .init(id: "home", node: .stack(path: [.feature(.detail)])), .init(id: "other"),
        ]))
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet, node: node)
        let store = try RouterStore(initialState: RouterState(root: .stack(path: [.detail], presentation: presentation)),
                                    configuration: .init(hostDescriptor: descriptor))
        let capture = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
        let declaration = try descriptor.presentationDeclaration(at: capture.child.path, in: store.state)
        #expect(declaration.id == "composer")
        #expect(declaration.shape == shape)
        try store.validateHostRenderer(shape: shape, at: capture.child.path, rootDeclarations: roots)
        let home = store.scope(at: capture.child.path.appending("home"))
        try store.validateHostRenderer(shape: .stack, at: home.path,
                                       rootDeclarations: [.init(meaning: .route(.feature(.home)))])
        do {
            try store.validateHostRenderer(shape: .stack, at: home.path,
                                           rootDeclarations: [.init(meaning: .route(.feature(.detail)))])
            Issue.record("A same-shape child renderer changed its frozen root route")
        } catch { #expect(error.code == .rendererMismatch) }
        #expect(capture.child.store === store)
        #expect(capture.child.path == RouterScopePath.root.appendingPresentation(presentation.id))
        _ = await home.perform(.push(.feature(.home)))
        #expect(home.observedPath == [.feature(.detail), .feature(.home)])
        #expect(capture.owner.observedPath == [.detail])
        #expect(capture.isCurrent)
        #expect(store.revision == 1)
    }

    @MainActor private final class CaptureBox { var value: RouterNavigationPresentationCapture<R>? }
}
