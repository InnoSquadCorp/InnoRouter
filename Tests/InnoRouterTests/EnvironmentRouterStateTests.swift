import Observation
import Testing

import InnoRouter

private enum EnvironmentStateRoute: Route {
    case home
    case detail
    case sheet
}

@Suite("Environment router state")
@MainActor
struct EnvironmentRouterStateTests {
    @MainActor
    private final class ChangeFlag {
        var value = false
    }

    @Test("Reader exposes narrow stack state without mutation authority")
    func stackProjection() async {
        let store = RouterStore<EnvironmentStateRoute>()
        let reader = RouterStateReader(scope: store.scope())

        #expect(reader.isAvailable)
        #expect(reader.scopePath == .root)
        #expect(!reader.canGoBack)
        #expect(!reader.canDismissPresentation)

        _ = await store.perform(
            .push(.detail),
            context: .init(source: .system)
        )
        #expect(reader.path == [.detail])
        #expect(reader.canGoBack)
        #expect(store.scope().reconciliationRevision == 1)

        _ = await store.perform(.present(.init(route: .sheet, style: .sheet)))
        #expect(reader.presentation?.route == .sheet)
        #expect(reader.canDismissPresentation)
    }

    @Test("Reader projects selection, badges, and whole-state scenes")
    func containerAndApplicationProjection() async throws {
        let container = try RouterContainerState<EnvironmentStateRoute>(
            style: .tabs,
            selection: "home",
            branches: [
                RouterBranch(id: "home"),
                RouterBranch(id: "settings"),
            ]
        )
        let store = RouterStore(
            initialState: try RouterState(root: .container(container))
        )
        let reader = RouterStateReader(scope: store.scope())

        _ = await store.perform(.setBadge(3, for: "settings"))
        _ = await store.perform(.openWindow(.init(route: .detail)))
        _ = await store.perform(.enterImmersiveSpace(.init(id: "focus", route: .home)))

        #expect(reader.selection == "home")
        #expect(reader.badges == ["settings": 3])
        #expect(reader.windows.count == 1)
        #expect(reader.immersiveSpace?.id == "focus")
    }

    @Test("Narrow readers ignore unrelated whole-state changes")
    func narrowObservation() async {
        let store = RouterStore<EnvironmentStateRoute>()
        let reader = RouterStateReader(scope: store.scope())
        let flag = ChangeFlag()

        withObservationTracking {
            _ = reader.path
        } onChange: {
            Task { @MainActor in flag.value = true }
        }

        _ = await store.perform(.openWindow(.init(route: .detail)))
        for _ in 0..<8 { await Task.yield() }
        #expect(!flag.value)

        _ = await store.perform(.push(.detail))
        for _ in 0..<8 { await Task.yield() }
        #expect(flag.value)
    }

    @Test("A system binding reconciles only its exact sibling scope")
    func scopedSystemReconciliation() async throws {
        let container = try RouterContainerState<EnvironmentStateRoute>(
            style: .tabs,
            selection: "first",
            branches: [
                RouterBranch(id: "first"),
                RouterBranch(id: "second"),
            ]
        )
        let store = RouterStore(
            initialState: try RouterState(root: .container(container))
        )
        let root = store.scope()
        let first = store.scope(at: ["first"])
        let second = store.scope(at: ["second"])

        _ = await store.perform(
            .scoped("first", .replaceStack([.detail])),
            context: .init(source: .system)
        )

        #expect(first.reconciliationRevision == 1)
        #expect(root.reconciliationRevision == 0)
        #expect(second.reconciliationRevision == 0)
        #expect(first.node == .stack(path: [.detail]))
        #expect(second.node == .stack())
    }
}
