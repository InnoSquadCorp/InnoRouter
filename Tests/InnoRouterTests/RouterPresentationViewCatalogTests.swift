import Foundation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum PresentationCatalogRoute: String, DestinationRoute, RouterSceneRoute {
    case outer, inner, detail
    static func destination(for route: Self) -> some View { Text(route.rawValue) }
    static let routerScenes: [RouterSceneDescriptor<Self>] = [
        .init(route: .outer, id: "window", style: .window),
        .init(route: .inner, id: "space", style: .immersiveSpace),
    ]
}

@Suite("Frozen recursive native presentation renderers", .tags(.unit), .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationViewCatalogTests {
    private typealias R = PresentationCatalogRoute

    private func stack(_ id: String) -> RouterHostViewDescriptor<R> {
        .stack(declarationID: id) { _ in Text(id) }
    }

    private func tabs() -> RouterHostViewDescriptor<R> {
        .tabs([
            .init("home", content: stack("home-root")) { _ in Text("Home") },
            .init("other", content: stack("other-root")) { _ in Text("Other") },
        ])
    }

    @Test("Default stack is explicit and its native item uses incarnation identity")
    func defaultStackAndCaptureIdentity() async throws {
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet, node: .stack(path: [.detail]))
        let store = try RouterStore(initialState: RouterState(root: .stack(presentation: presentation)),
                                    configuration: .init(hostDescriptor: .init(root: .stack)))
        let oldBinding = makeRouterNativeNavigationPresentationBinding(scope: store.scope(), style: .sheet)
        let old = try #require(oldBinding.wrappedValue)
        let entry = try RouterPresentationViewCatalog<R>.stack.resolve(old)
        #expect(entry.id == "stack")
        #expect(entry.shape == .stack)
        #expect(old.child.observedPath == [.detail])
        _ = await store.replaceSubtree(at: old.child.path, with: .stack(path: [.detail]))
        let freshBinding = makeRouterNativeNavigationPresentationBinding(scope: store.scope(), style: .sheet)
        let fresh = try #require(freshBinding.wrappedValue)
        #expect(oldBinding.wrappedValue == nil)
        #expect(old.id != fresh.id)
        #expect(old.handle.id == fresh.handle.id)
        var events = store.events.makeAsyncIterator()
        oldBinding.wrappedValue = nil
        while let event = await events.next() { if case .rejected = event { break } }
        #expect(fresh.isCurrent)
        #expect(store.presentationHandle() == fresh.handle)
    }

    @Test("Custom descriptor renders declared canonical children in the same Store")
    func nestedCustomRenderer() throws {
        var children: [RouterHostRenderedBranch<R>] = []
        let rendering = RouterHostViewDescriptor<R>.custom(declarationID: "composer-layout", branches: [
            .init("tabs", content: tabs()), .init("inspector", content: stack("inspector-root")),
        ]) { _, rendered in
            recordChildren(rendered)
        }
        func recordChildren(_ rendered: [RouterHostRenderedBranch<R>]) -> some View {
            children = rendered
            return EmptyView()
        }
        let entry = RouterPresentationViewEntry("composer", rendering: rendering)
        let catalog = RouterPresentationViewCatalog(entries: [entry])
        let node = RouterNode<R>.container(try .init(style: .custom("composer-layout"), selection: "tabs", branches: [
            .init(id: "tabs", node: .container(try .init(style: .tabs, selection: "home", branches: [
                .init(id: "home", node: .stack(path: [.detail])), .init(id: "other"),
            ]))), .init(id: "inspector"),
        ]))
        let presentation = RouterPresentation<R>(route: .outer, style: .sheet, node: node)
        let descriptor = RouterHostDescriptor<R>(root: .stack, presentations: .init(
            entries: [entry.declaration], declaration: { _ in "composer" }
        ))
        let store = try RouterStore(initialState: RouterState(root: .stack(presentation: presentation)),
                                    configuration: .init(hostDescriptor: descriptor))
        let capture = try #require(RouterNavigationPresentationCapture(owner: store.scope()))
        _ = try catalog.resolve(capture).render(capture: capture, destination: R.destination(for:))
        #expect(children.map(\.id) == ["tabs", "inspector"])
        #expect(children.allSatisfy { $0.scope.store === store })
        #expect(children[0].scope.path == capture.child.path.appending("tabs"))
        #expect(store.scope(at: children[0].scope.path.appending("home")).observedPath == [.detail])
        #expect(store.revision == 0)
    }

    @Test("Frozen native catalogs match IDs, shapes and opaque root meanings even while inactive")
    func mismatchesFailClosed() throws {
        let expected = RouterPresentationViewEntry("composer", rendering: tabs())
        let descriptor = RouterHostDescriptor<R>(root: .stack, presentations: .init(
            entries: [expected.declaration], declaration: { _ in "composer" }
        ))
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: descriptor))
        let wrongID = RouterPresentationViewCatalog(entries: [.init("other-secret-id", rendering: tabs())])
        let wrongShape = RouterPresentationViewCatalog(entries: [.init("composer", rendering: stack("root"))])
        let wrongRoots = RouterPresentationViewCatalog(entries: [.init("composer", rendering: .tabs([
            .init("home", content: stack("changed-root-secret")) { _ in Text("Home") },
            .init("other", content: stack("other-root")) { _ in Text("Other") },
        ]))])
        for invalid in [wrongID, wrongShape, wrongRoots] {
            do { try invalid.validate(for: store); Issue.record("Expected frozen native catalog mismatch") }
            catch {
                #expect(error.code == .rendererMismatch)
                #expect(error.description == RouterHostValidationFailure.Code.rendererMismatch.rawValue)
                #expect(!error.debugDescription.contains("secret"))
            }
        }
        #expect(store.revision == 0)
    }

    @Test("Equivalent root mapping order does not change a presentation renderer")
    func rootMappingOrder() throws {
        let entry = RouterPresentationViewEntry("composer", rendering: tabs())
        let declared = RouterHostCatalogEntry<R>(entry.id, shape: entry.shape,
                                                 rootDeclarations: Array(entry.rootDeclarations.reversed()))
        let descriptor = RouterHostDescriptor<R>(root: .stack, presentations: .init(
            entries: [declared], declaration: { _ in "composer" }
        ))
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: descriptor))
        try RouterPresentationViewCatalog(entries: [entry]).validate(for: store)
        #expect(store.revision == 0)
    }

    @Test("Host bridges expose typed catalog mismatch without mutating the Store")
    func bridgeFailure() throws {
        let entry = RouterPresentationViewEntry("composer", rendering: tabs())
        let descriptor = RouterHostDescriptor<R>(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))],
            presentations: .init(entries: [entry.declaration], declaration: { _ in "composer" })
        )
        let store = try RouterStore<R>(configuration: .init(hostDescriptor: descriptor))
        let old = store.state
        let invalid = RouterHost(store: store) { Text("Root") }
        #expect(invalid.validationFailure?.code == .rendererMismatch)
        let valid = RouterHost(store: store, presentations: .init(entries: [entry])) { Text("Root") }
        #expect(valid.validationFailure == nil)
        #expect(store.state == old)
        #expect(store.revision == 0)
    }
    @Test("Scene adapters require their declared descriptor and preserve absent-scene repair")
    func sceneRendererContracts() throws {
        let rendering = tabs()
        let node = RouterNode<R>.container(try .init(style: .tabs, selection: "home", branches: [
            .init(id: "home"), .init(id: "other"),
        ]))
        let window = RouterWindow<R>(route: .outer, node: node)
        let space = RouterImmersiveSpace<R>(id: "space", route: .inner, node: node)
        let descriptor = RouterHostDescriptor<R>(root: .stack,
            windows: .init(entries: [.init("window", shape: rendering.shape, rootDeclarations: rendering.rootDeclarations)], declaration: { _ in "window" }),
            immersiveSpaces: .init(entries: [.init("space", shape: rendering.shape, rootDeclarations: rendering.rootDeclarations)], declaration: { _ in "space" }))
        let state = try RouterState(root: .stack(), windows: [window], immersiveSpace: space)
        let store = try RouterStore(initialState: state, configuration: .init(hostDescriptor: descriptor))
        #expect(RouterWindowHost(id: window.id, store: store).validationFailure?.code == .rendererMismatch)
        #expect(RouterImmersiveSpaceHost(id: "space", store: store).validationFailure?.code == .rendererMismatch)
        #expect(RouterWindowHost(id: window.id, store: store, rendering: rendering).validationFailure == nil)
        #expect(RouterImmersiveSpaceHost(id: "space", store: store, rendering: rendering).validationFailure == nil)
        #expect(RouterWindowHost(id: UUID(), store: store).validationFailure == nil)
        #expect(RouterImmersiveSpaceHost(id: "absent", store: store).validationFailure == nil)
        #expect(store.state == state)
        #expect(store.revision == 0)
    }

    @Test("Invalid absent scene paths fail admission instead of entering native close repair")
    func invalidScenePaths() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 16))
        let store = try RouterStore<R>(configuration: .init(resourceBudget: budget, hostDescriptor: .init(root: .stack)))
        #expect(RouterImmersiveSpaceHost(id: "", store: store).validationFailure?.code == .invalidScope)
        #expect(RouterImmersiveSpaceHost(id: String(repeating: "x", count: 17), store: store).validationFailure?.code == .resourceLimit)
        #expect(RouterImmersiveSpaceHost(id: "absent", store: store).validationFailure == nil)
        #expect(RouterWindowHost(id: UUID(), store: store).validationFailure == nil)
        #expect(store.revision == 0)
    }
}
