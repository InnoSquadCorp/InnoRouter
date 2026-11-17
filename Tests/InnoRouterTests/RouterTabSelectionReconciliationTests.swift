import Observation
import SwiftUI
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum TabReconciliationRoute: String, DestinationRoute, RouterTabRoute {
    case home
    case inbox

    enum Tab: String, RouterTab {
        case home
        case inbox

        var title: LocalizedStringResource { self == .home ? "Home" : "Inbox" }
        var systemImage: String { self == .home ? "house" : "tray" }
        var routerScopeID: RouterScopeID { RouterScopeID(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home),
        .init(tab: .inbox, root: .inbox),
    ]

    @MainActor
    static func destination(for route: Self) -> some View {
        Text(route.rawValue)
    }
}

/// The native containers that bind `TabView(selection:)` to one scope.
enum RouterTabReconciliationSurface: String, CaseIterable, Sendable {
    /// `RouterTabHost` over the route's tab catalog.
    case tabHost
    /// `RouterHostViewDescriptor.tabs`, as `RouterScopedHost` renders it.
    case descriptorTabs
}

/// Store rejections that reach a selection `TabView` has already displayed.
enum RouterTabReconciliationRejection: String, CaseIterable, Sendable {
    case policy
    case busy
}

/// Holds one request inside its policy so a later request meets a busy Store.
@MainActor
private final class TabReconciliationGate {
    private let entered: AsyncStream<Void>
    private let didEnter: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, didEnter) = AsyncStream<Void>.makeStream()
        (releases, releaseContinuation) = AsyncStream<Void>.makeStream()
    }

    func wait() async {
        didEnter.yield(())
        for await _ in releases { break }
    }

    func waitUntilEntered() async throws {
        _ = try await firstElement(from: entered, what: "busy policy entered")
    }

    func release() {
        releaseContinuation.finish()
    }
}

/// What SwiftUI uses from a mounted tab container: the body it re-evaluates
/// when an observed value changes, and the binding `TabView` reads and writes.
@MainActor
private struct RenderedTabContainer {
    let evaluateBody: @MainActor () -> Void
    let selection: Binding<RouterScopeID?>
}

@MainActor
private final class TabReconciliationFixture {
    typealias R = TabReconciliationRoute

    let store: RouterStore<R>
    let scope: RouterScope<R>
    let gate: TabReconciliationGate
    private let terminals: AsyncStream<RouterEvent<R>>

    init(rejection: RouterTabReconciliationRejection) throws {
        let gate = TabReconciliationGate()
        let (terminals, didFinish) = AsyncStream<RouterEvent<R>>.makeStream()
        let policy: RouterPolicy<R> = switch rejection {
        case .policy:
            RouterPolicy(name: "reject-native-selection") { transition in
                if case .select = transition.action { return .reject("denied") }
                return .allow
            }
        case .busy:
            RouterPolicy(name: "hold-badge-update") { transition in
                if case .setBadge = transition.action { await gate.wait() }
                return .allow
            }
        }
        let configuration = RouterStoreConfiguration<R>(
            hostDescriptor: try RouterTabCatalog(R.routerTabs).hostDescriptor(),
            policies: [policy],
            schedulingPolicy: rejection == .busy ? .rejectWhileBusy : .serialize,
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
        let tabs = try RouterContainerState<R>(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "inbox")]
        )
        let store = try RouterStore(
            initialState: try RouterState(root: .container(tabs)),
            configuration: configuration
        )
        self.store = store
        self.scope = store.scope()
        self.gate = gate
        self.terminals = terminals
    }

    var selection: RouterScopeID? {
        guard case .container(let container) = store.state.root else { return nil }
        return container.selection
    }

    func render(_ surface: RouterTabReconciliationSurface) throws -> RenderedTabContainer {
        switch surface {
        case .tabHost:
            let host = try RouterTabHost(store: store)
            // `RouterTabHost.body` returns the validated surface, whose body
            // builds `TabView`. Evaluating both covers every read SwiftUI tracks.
            return RenderedTabContainer(
                evaluateBody: { _ = host.body.body },
                selection: host.selectionBinding(scope)
            )
        case .descriptorTabs:
            let tabs: [RouterHostTabView<R>] = [
                .init("home", content: .route(.home)) { _ in Text(verbatim: "Home") },
                .init("inbox", content: .route(.inbox)) { _ in Text(verbatim: "Inbox") },
            ]
            // `RouterScopedHost` admits this declaration and renders it with
            // the surface constructed below.
            _ = try RouterScopedHost(scope: scope, rendering: .tabs(tabs))
            let surface = RouterDescriptorTabsSurface(scope: scope, tabs: tabs)
            return RenderedTabContainer(
                evaluateBody: { _ = surface.body },
                selection: surface.selection
            )
        }
    }

    func nextTerminal() async throws -> RouterEvent<R> {
        try await firstElement(from: terminals, what: "native tab selection terminal event")
    }
}

@Suite("Router tab selection reconciliation", .tags(.unit), .timeLimit(.minutes(1)))
@MainActor
struct RouterTabSelectionReconciliationTests {
    @Test(
        "A rejected native tab selection re-renders the tab container at the canonical tab",
        arguments: RouterTabReconciliationSurface.allCases, RouterTabReconciliationRejection.allCases
    )
    func rejectedSelectionReconcilesContainer(
        surface: RouterTabReconciliationSurface,
        rejection: RouterTabReconciliationRejection
    ) async throws {
        let fixture = try TabReconciliationFixture(rejection: rejection)
        defer { fixture.gate.release() }
        let container = try fixture.render(surface)
        var busyRequest: Task<RouterOutcome<TabReconciliationRoute>, Never>?
        if rejection == .busy {
            busyRequest = Task { await fixture.store.perform(.setBadge(2, for: "inbox")) }
            try await fixture.gate.waitUntilEntered()
        }

        // A rejection leaves the selection equal, so only the reconciliation
        // revision can tell SwiftUI to rebuild `TabView` and re-read it.
        let invalidated = Mutex(false)
        withObservationTracking {
            container.evaluateBody()
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        // The native control writes the tapped tab before the Store decides.
        container.selection.wrappedValue = "inbox"
        guard case .rejected(_, _, let revision, let reason, _) = try await fixture.nextTerminal() else {
            Issue.record("Expected the Store to reject the native selection")
            return
        }
        switch rejection {
        case .policy:
            #expect(reason == .policy(name: "reject-native-selection", message: "denied"))
        case .busy:
            guard case .busy = reason else {
                Issue.record("Expected a busy rejection, received \(reason)")
                return
            }
        }
        #expect(revision == 0)
        #expect(fixture.scope.reconciliationRevision == 1)
        #expect(invalidated.withLock { $0 }, "The tab container must re-render after a rejected selection")
        #expect(container.selection.wrappedValue == "home")
        #expect(fixture.selection == "home")
        #expect(fixture.store.revision == 0)

        fixture.gate.release()
        if let busyRequest, case .rejected = await busyRequest.value {
            Issue.record("The held badge update must still commit after the busy rejection")
        }
    }
}
