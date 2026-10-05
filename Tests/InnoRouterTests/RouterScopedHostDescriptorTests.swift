import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum ScopedHostDescriptorRoute: String, DestinationRoute {
    case detail

    static func destination(for route: Self) -> some View { Text(route.rawValue) }
}

@Suite("Frozen scoped native host declarations", .tags(.unit))
@MainActor
struct RouterScopedHostDescriptorTests {
    private typealias R = ScopedHostDescriptorRoute

    private func stack() -> RouterHostViewDescriptor<R> {
        .stack { scope in Text(scope.path.description) }
    }

    private func state() throws -> RouterState<R> {
        try RouterState(root: .container(.init(
            style: .custom("app"), selection: "feature", branches: [
                .init(id: "feature", node: .container(.init(
                    style: .tabs, selection: "home", branches: [
                        .init(id: "home"), .init(id: "inbox"),
                    ]
                ))),
                .init(id: "sibling"),
            ]
        )))
    }

    private func tabs() -> RouterHostViewDescriptor<R> {
        .tabs([
            .init("home", content: stack()) { scope in Text(scope.path.description) },
            .init("inbox", content: stack()) { scope in Text(scope.path.description) },
        ])
    }

    private func root(_ child: RouterHostViewDescriptor<R>) -> RouterHostViewDescriptor<R> {
        .custom(declarationID: "app", branches: [
            .init("feature", content: child), .init("sibling", content: stack()),
        ]) { _, branches in
            ForEach(branches) { branch in branch }
        }
    }

    @Test("Frozen nested shape and read-only child host share the owner Store")
    func nestedHostUsesOwningStore() async throws {
        let child = tabs()
        let renderer = root(child)
        var configuration = RouterStoreConfiguration<R>()
        configuration.hostDescriptor = RouterHostDescriptor(root: renderer.shape)
        let store = try RouterStore(initialState: state(), configuration: configuration)
        let before = store.state
        let scope = store.scope(at: ["feature"])
        _ = try RouterScopedHost(scope: scope, rendering: child)
        _ = try RouterScopedHost(scope: scope, rendering: child)
        #expect(store.state == before)
        #expect(store.revision == 0)

        guard case .applied = await scope.perform(.scoped("inbox", .push(.detail))) else {
            Issue.record("Expected nested scope to forward to its Store")
            return
        }
        #expect(store.revision == 1)
        #expect(store.state.node(at: ["feature", "inbox"]) == .stack(path: [.detail]))
        #expect(store.state.node(at: ["sibling"]) == before.node(at: ["sibling"]))
        #expect(scope.store === store)
    }

    @Test("Host creation requires an installed contract and never installs one")
    func missingContract() throws {
        let store = RouterStore<R>()
        #expect(throws: RouterHostValidationFailure(code: .required)) {
            try RouterScopedHost(scope: store.scope(), rendering: stack())
        }
        #expect(store.hostDescriptor == nil)
        #expect(store.revision == 0)
    }

    @Test("Renderer mismatch is typed and leaves the owner untouched")
    func rendererMismatch() throws {
        let renderer = root(tabs())
        var configuration = RouterStoreConfiguration<R>()
        configuration.hostDescriptor = RouterHostDescriptor(root: renderer.shape)
        let store = try RouterStore(initialState: state(), configuration: configuration)
        let before = store.state
        do {
            _ = try RouterScopedHost(scope: store.scope(at: ["feature"]), rendering: stack())
            Issue.record("A stack renderer cannot stand in for tabs")
        } catch {
            #expect(error.code == .rendererMismatch)
            #expect(error.scope == ["feature"])
        }
        #expect(store.state == before)
        #expect(store.revision == 0)
    }

    @Test("Custom rendering exposes only declared same-Store children")
    func customScopedSurface() throws {
        var capturedRoot: RouterScope<R>?
        var capturedChildren: [RouterHostRenderedBranch<R>] = []
        let renderer = RouterHostViewDescriptor<R>.custom(declarationID: "app", branches: [
            .init("feature", content: tabs()), .init("sibling", content: stack()),
        ]) { scope, children in
            capture(scope, children)
        }
        func capture(_ scope: RouterScope<R>, _ children: [RouterHostRenderedBranch<R>]) -> some View {
            capturedRoot = scope
            capturedChildren = children
            return EmptyView()
        }
        var configuration = RouterStoreConfiguration<R>()
        configuration.hostDescriptor = RouterHostDescriptor(root: renderer.shape)
        let store = try RouterStore(initialState: state(), configuration: configuration)
        let scope = store.scope()
        _ = renderer.render(scope)
        #expect(capturedRoot === scope)
        #expect(capturedChildren.map(\.id) == ["feature", "sibling"])
        #expect(capturedChildren.map(\.scope.path) == [["feature"], ["sibling"]])
        #expect(capturedChildren.allSatisfy { $0.scope.store === store })
        #expect(capturedChildren[0].scope === store.scope(at: ["feature"]))
    }

    @Test("Explicit preservation retains dormant data but rejects selecting it")
    func dormantBranch() async throws {
        let renderer = RouterHostViewDescriptor<R>.tabs([
            .init("home", content: stack()) { _ in Text("Home") },
        ], orphanPolicy: .preserveDormant)
        let state = try RouterState<R>(root: .container(.init(
            style: .tabs, selection: "home", branches: [
                .init(id: "home"), .init(id: "old", node: .stack(path: [.detail])),
            ]
        )))
        var configuration = RouterStoreConfiguration<R>()
        configuration.hostDescriptor = RouterHostDescriptor(root: renderer.shape)
        let store = try RouterStore(initialState: state, configuration: configuration)
        _ = try RouterScopedHost(scope: store.scope(), rendering: renderer)
        guard case .rejected = await store.perform(.select("old")) else {
            Issue.record("Dormant data must not acquire a renderer implicitly")
            return
        }
        #expect(store.state == state)
        #expect(store.revision == 0)
    }

    @Test("Same-shape owner replacement expires captured scoped hosts")
    func replacementExpiresScope() async throws {
        let renderer = stack()
        let descriptor = RouterHostDescriptor<R>(root: renderer.shape)
        var configuration = RouterStoreConfiguration<R>()
        configuration.hostDescriptor = descriptor
        let store = try RouterStore(configuration: configuration)
        let scope = store.scope()
        _ = try RouterScopedHost(scope: scope, rendering: renderer)
        guard case .applied = await store.replaceHost(
            with: .init(state: store.state), descriptor: descriptor
        ) else {
            Issue.record("Expected explicit same-state replacement to rotate authority")
            return
        }
        #expect(throws: RouterHostValidationFailure(code: .stale)) {
            try RouterScopedHost(scope: scope, rendering: renderer)
        }
        _ = try RouterScopedHost(scope: store.scope(), rendering: renderer)
        guard case .rejected = await scope.perform(.push(.detail)) else {
            Issue.record("Expired child host cannot write the replacement")
            return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 1)
    }
}
