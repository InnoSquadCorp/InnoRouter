import Observation
import SwiftUI
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

#if !os(watchOS)
private enum SplitReconciliationRoute: String, DestinationRoute {
    case item

    @MainActor
    static func destination(for route: Self) -> some View {
        Text(route.rawValue)
    }
}

/// The native containers that bind `NavigationSplitView` columns to one scope.
enum RouterSplitReconciliationSurface: String, CaseIterable, Sendable {
    /// `RouterSplitHost`.
    case splitHost
    /// `RouterThreeColumnSplitHost`.
    case threeColumnSplitHost
    /// `RouterHostViewDescriptor.splitTwo`, as `RouterScopedHost` renders it.
    case descriptorSplitTwo
    /// `RouterHostViewDescriptor.splitThree`, as `RouterScopedHost` renders it.
    case descriptorSplitThree

    var hasContentColumn: Bool {
        self == .threeColumnSplitHost || self == .descriptorSplitThree
    }
}

/// The split bindings a native control writes before the Store decides.
enum RouterSplitReconciliationBinding: String, CaseIterable, Sendable {
    case columnVisibility
    case preferredCompactColumn
}

/// What SwiftUI uses from a mounted split container: the body it re-evaluates
/// when an observed value changes, and the bindings `NavigationSplitView`
/// reads and writes.
@MainActor
private struct RenderedSplitContainer {
    let evaluateBody: @MainActor () -> Void
    let columnVisibility: Binding<NavigationSplitViewVisibility>
    let preferredCompactColumn: Binding<NavigationSplitViewColumn>
}

@MainActor
private final class SplitReconciliationFixture {
    typealias R = SplitReconciliationRoute

    let store: RouterStore<R>
    let scope: RouterScope<R>
    private let threeColumn: Bool
    private let terminals: AsyncStream<RouterEvent<R>>

    init(threeColumn: Bool) throws {
        let (terminals, didFinish) = AsyncStream<RouterEvent<R>>.makeStream()
        let policy = RouterPolicy<R>(name: "reject-native-columns") { transition in
            switch transition.action {
            case .setSplitVisibility, .setPreferredCompactColumn: .reject("denied")
            default: .allow
            }
        }
        let shape: RouterHostShape
        let roots: [RouterHostRootDeclaration<R>]
        if threeColumn {
            shape = RouterThreeColumnSplitLayout.standard.hostShape
            roots = RouterThreeColumnSplitLayout.standard.hostRootDeclarations(
                for: R.self, sidebarDeclarationID: "split.sidebar",
                contentDeclarationID: "split.content", detailDeclarationID: "split.detail"
            )
        } else {
            shape = RouterTwoColumnSplitLayout.standard.hostShape
            roots = RouterTwoColumnSplitLayout.standard.hostRootDeclarations(
                for: R.self, sidebarDeclarationID: "split.sidebar", detailDeclarationID: "split.detail"
            )
        }
        let configuration = RouterStoreConfiguration<R>(
            hostDescriptor: .init(root: shape, rootDeclarations: roots),
            policies: [policy],
            onEvent: { event in
                switch event {
                case .committed(_, _, _, _, let context),
                     .unchanged(_, _, _, let context),
                     .deferred(_, _, _, _, let context),
                     .rejected(_, _, _, _, let context):
                    if context.source == .system { didFinish.yield(event) }
                default:
                    break
                }
            }
        )
        let split = try RouterSplitState(
            sidebar: "sidebar",
            content: threeColumn ? "content" : nil,
            detail: "detail"
        )
        var branches = [RouterBranch<R>(id: "sidebar")]
        if threeColumn { branches.append(.init(id: "content")) }
        branches.append(.init(id: "detail"))
        let container = try RouterContainerState(
            style: .split,
            selection: "detail",
            branches: branches,
            split: split
        )
        let store = try RouterStore(
            initialState: try RouterState(root: .container(container)),
            configuration: configuration
        )
        self.store = store
        self.scope = store.scope()
        self.threeColumn = threeColumn
        self.terminals = terminals
    }

    func render(_ surface: RouterSplitReconciliationSurface) throws -> RenderedSplitContainer {
        switch surface {
        case .splitHost:
            let host = try RouterSplitHost(
                store: store, sidebarDeclarationID: "split.sidebar", detailDeclarationID: "split.detail"
            ) {
                Text(verbatim: "Sidebar")
            } root: {
                Text(verbatim: "Detail")
            }
            // `body` returns the validated surface, whose body builds
            // `NavigationSplitView`. Evaluating both covers every read SwiftUI
            // tracks.
            return RenderedSplitContainer(
                evaluateBody: { _ = host.body.body },
                columnVisibility: splitVisibilityBinding(scope),
                preferredCompactColumn: preferredCompactColumnBinding(scope)
            )
        case .threeColumnSplitHost:
            let host = try RouterThreeColumnSplitHost(
                store: store, sidebarDeclarationID: "split.sidebar",
                contentDeclarationID: "split.content", detailDeclarationID: "split.detail"
            ) {
                Text(verbatim: "Sidebar")
            } content: {
                Text(verbatim: "Content")
            } detail: {
                Text(verbatim: "Detail")
            }
            return RenderedSplitContainer(
                evaluateBody: { _ = host.body.body },
                columnVisibility: splitVisibilityBinding(scope),
                preferredCompactColumn: preferredCompactColumnBinding(scope)
            )
        case .descriptorSplitTwo, .descriptorSplitThree:
            let sidebar = Self.branch("sidebar", declarationID: "split.sidebar")
            let content = threeColumn ? Self.branch("content", declarationID: "split.content") : nil
            let detail = Self.branch("detail", declarationID: "split.detail")
            let rendering: RouterHostViewDescriptor<R> = if let content {
                .splitThree(sidebar: sidebar, content: content, detail: detail)
            } else {
                .splitTwo(sidebar: sidebar, detail: detail)
            }
            // `RouterScopedHost` admits this declaration and renders it with
            // the surface constructed below.
            _ = try RouterScopedHost(scope: scope, rendering: rendering)
            let split = RouterDescriptorSplitSurface(scope: scope, sidebar: sidebar, content: content, detail: detail)
            return RenderedSplitContainer(
                evaluateBody: { _ = split.body },
                columnVisibility: split.columnVisibility,
                preferredCompactColumn: split.preferredCompactColumn
            )
        }
    }

    func nextTerminal() async throws -> RouterEvent<R> {
        try await firstElement(from: terminals, what: "native split column terminal event")
    }

    private static func branch(_ id: RouterScopeID, declarationID: String) -> RouterHostViewBranch<R> {
        RouterHostViewBranch(id, content: .stack(declarationID: declarationID) { _ in
            Text(verbatim: declarationID)
        })
    }
}

@Suite("Router split column reconciliation", .tags(.unit), .timeLimit(.minutes(1)))
@MainActor
struct RouterSplitColumnReconciliationTests {
    @Test(
        "A rejected native column change re-renders the split container at the canonical columns",
        arguments: RouterSplitReconciliationSurface.allCases, RouterSplitReconciliationBinding.allCases
    )
    func rejectedColumnChangeReconcilesContainer(
        surface: RouterSplitReconciliationSurface,
        binding: RouterSplitReconciliationBinding
    ) async throws {
        let fixture = try SplitReconciliationFixture(threeColumn: surface.hasContentColumn)
        let container = try fixture.render(surface)

        // A rejection leaves the split state equal, so only the reconciliation
        // revision can tell SwiftUI to rebuild `NavigationSplitView` and
        // re-read its bindings.
        let invalidated = Mutex(false)
        withObservationTracking {
            container.evaluateBody()
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        // The native control writes the new column state before the Store decides.
        switch binding {
        case .columnVisibility:
            container.columnVisibility.wrappedValue = .detailOnly
        case .preferredCompactColumn:
            container.preferredCompactColumn.wrappedValue = .sidebar
        }
        guard case .rejected(_, _, let revision, let reason, _) = try await fixture.nextTerminal() else {
            Issue.record("Expected the Store to reject the native column change")
            return
        }
        #expect(reason == .policy(name: "reject-native-columns", message: "denied"))
        #expect(revision == 0)
        #expect(fixture.scope.reconciliationRevision == 1)
        #expect(invalidated.withLock { $0 }, "The split container must re-render after a rejected column change")
        #expect(container.columnVisibility.wrappedValue == .automatic)
        #expect(container.preferredCompactColumn.wrappedValue == .detail)
        #expect(fixture.store.revision == 0)
    }
}
#endif
