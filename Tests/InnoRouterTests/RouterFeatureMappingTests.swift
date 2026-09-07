import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

@Suite("Feature route composition")
struct RouterFeatureMappingTests {
    @Test("Two same-kind windows isolate feature modal results by UUID")
    @MainActor
    func windowFeaturePresentationIntegration() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let state = try RouterState<Parent>(windows: [
            .init(id: firstID, route: .feature(.home)),
            .init(id: secondID, route: .feature(.home)),
        ])
        let store = RouterStore(initialState: state)
        let first = RouterFeatureScope(
            parent: store.scope(at: .window(firstID)),
            mapping: mapping
        )
        let result = Task { @MainActor in
            await first.present(.detail(9), expecting: String.self)
        }
        var events = store.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .committed = event { break }
        }

        guard case .stack(let firstNode) = store.state.windows[0].node,
              case .stack(let secondNode) = store.state.windows[1].node else {
            Issue.record("Expected independent window stacks")
            return
        }
        #expect(firstNode.presentation?.route == .feature(.detail(9)))
        #expect(secondNode.presentation == nil)

        try await first.finishPresentation(returning: "saved")
        #expect(await result.value == .value("saved"))
        #expect(store.state.windows.map(\.id) == [firstID, secondID])
        #expect(store.state.windows.allSatisfy { window in
            if case .stack(let stack) = window.node { return stack.presentation == nil }
            return false
        })
    }

    private enum Child: Hashable, Route {
        case home
        case detail(Int)
    }

    private enum Parent: Hashable, Route {
        case feature(Child)
        case sibling
    }

    private var mapping: RouterFeatureMapping<Parent, Child> {
        .init(
            id: "primary",
            namespace: "Parent.primary",
            route: .init(
                embed: Parent.feature,
                extract: {
                    guard case .feature(let child) = $0 else { return nil }
                    return child
                }
            )
        )
    }

    @Test("A queued feature request is rejected before mutation when its feature disappears")
    @MainActor
    func queuedFeatureRejectsBeforeMutation() async {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<Parent>(
            initialState: .rootStack(path: [.feature(.home)]),
            configuration: .init(
                policies: [
                    RouterPolicy(name: "replace-feature") { transition in
                        if case .apply = transition.action {
                            for await _ in gate { break }
                        }
                        return .allow
                    },
                ]
            )
        )
        let feature = RouterFeatureScope(parent: store.scope(), mapping: mapping)
        var events = store.events.makeAsyncIterator()
        let replacement = Task { @MainActor in
            await store.perform(.apply(.init(state: .rootStack(path: [.sibling]))))
        }
        guard case .started = await events.next() else {
            Issue.record("Expected parent replacement to enter policy preparation")
            gateContinuation.finish()
            return
        }
        var requests = store.requestObservations.makeAsyncIterator()
        let child = Task { @MainActor in
            await feature.perform(.push(.detail(1)))
        }
        _ = await requests.next()

        gateContinuation.finish()
        _ = await replacement.value
        let outcome = await child.value

        guard case .rejected(_, _, let revision, .featureProjection(
            .routeMismatch(namespace: "Parent.primary")
        )) = outcome else {
            Issue.record("Expected feature projection rejection")
            return
        }
        #expect(revision == 1)
        #expect(store.revision == 1)
        #expect(store.state == .rootStack(path: [.sibling]))
    }

    @Test("A queued typed feature presentation cannot commit after its feature disappears")
    @MainActor
    func queuedTypedFeaturePresentationRejectsBeforeMutation() async throws {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<Parent>(
            initialState: .rootStack(path: [.feature(.home)]),
            configuration: .init(policies: [
                RouterPolicy(name: "replace-feature") { transition in
                    if case .apply = transition.action {
                        for await _ in gate { break }
                    }
                    return .allow
                },
            ])
        )
        let feature = RouterFeatureScope(parent: store.scope(), mapping: mapping)
        var events = store.events.makeAsyncIterator()
        let replacement = Task { @MainActor in
            await store.perform(.apply(.init(state: .rootStack(path: [.sibling]))))
        }
        guard case .started = await events.next() else {
            Issue.record("Expected parent replacement to start")
            continuation.finish()
            return
        }
        var requests = store.requestObservations.makeAsyncIterator()
        let modal = Task { @MainActor in
            await feature.present(.detail(1), expecting: Int.self)
        }
        let modalRequest = try #require(await requests.next())

        continuation.finish()
        _ = await replacement.value
        while let event = await events.next() {
            switch event {
            case .committed(let id, _, _, _, _) where id == modalRequest.id,
                 .unchanged(let id, _, _, _) where id == modalRequest.id,
                 .deferred(let id, _, _, _, _) where id == modalRequest.id,
                 .rejected(let id, _, _, _, _) where id == modalRequest.id:
                break
            default:
                continue
            }
            break
        }

        #expect(store.revision == 1)
        #expect(store.state == .rootStack(path: [.sibling]))
        modal.cancel()
        #expect(await modal.value == .rejected(.featureProjection(
            .routeMismatch(namespace: "Parent.primary")
        )))
    }

    @Test("Projection fails instead of filtering a mixed feature subtree")
    func mixedProjectionFails() {
        let mixed = RouterNode<Parent>.stack(
            path: [.feature(.home), .sibling, .feature(.detail(1))]
        )

        #expect(throws: RouterFeatureProjectionError.routeMismatch(namespace: "Parent.primary")) {
            try mapping.project(mixed)
        }
    }

    @Test("Feature mappings reject application scene lifetime actions")
    func globalActionsFail() {
        let window = RouterWindow<Child>(route: .home)

        #expect(throws: RouterFeatureProjectionError.self) {
            try mapping.embed(.openWindow(window))
        }
        #expect(throws: RouterFeatureProjectionError.self) {
            try mapping.embed(.dismissImmersiveSpace)
        }
    }

    @Test("Replacing a nested node preserves siblings and scene identity")
    func nestedReplacement() throws {
        let featureID: RouterScopeID = "feature"
        let siblingID: RouterScopeID = "sibling"
        let root = try RouterContainerState<Parent>(
            style: .custom("root"),
            selection: featureID,
            branches: [
                .init(id: featureID, node: .stack(path: [.feature(.home)])),
                .init(id: siblingID, node: .stack(path: [.sibling])),
            ]
        )
        let windowID = UUID()
        let state = try RouterState(
            root: .container(root),
            windows: [.init(id: windowID, route: .sibling)]
        )

        let replaced = try state.replacingNode(
            .stack(path: [.feature(.detail(2))]),
            at: [featureID]
        )

        #expect(replaced.node(at: [featureID]) == .stack(path: [.feature(.detail(2))]))
        #expect(replaced.node(at: [siblingID]) == .stack(path: [.sibling]))
        #expect(replaced.windows.map(\.id) == [windowID])
    }

    @Test("A feature plan cannot smuggle application scenes into its parent")
    func featurePlanRejectsScenes() throws {
        let state = try RouterState<Child>(
            windows: [.init(route: .home)]
        )

        #expect(throws: RouterFeatureProjectionError.globalStateNotAllowed(namespace: "Parent.primary")) {
            try mapping.embedPlanRoot(.init(state: state))
        }
    }

    @Test("Nested containers and presentations round-trip without losing metadata")
    func containerAndPresentationRoundTrip() throws {
        let presentationID = UUID(
            uuidString: "F0000000-0000-0000-0000-000000000001"
        )!
        let child = try RouterContainerState<Child>(
            style: .tabs,
            selection: "first",
            branches: [
                .init(
                    id: "first",
                    node: .stack(
                        path: [.home],
                        presentation: .init(
                            id: presentationID,
                            route: .detail(7),
                            style: .sheet
                        )
                    )
                ),
                .init(id: "second", node: .stack(path: [.detail(8)])),
            ],
            badges: ["second": 2]
        )
        let node = RouterNode<Child>.container(child)

        let embedded = try mapping.embed(node)
        let projected = try mapping.project(embedded)

        #expect(projected == node)
        #expect(try mapping.projectState(from: embedded).root == node)
    }

    @Test("Every application-owned action reports its exact rejected action kind")
    func globalActionDiagnostics() throws {
        let windowID = UUID(
            uuidString: "F0000000-0000-0000-0000-000000000002"
        )!
        let actions: [(RouterAction<Child>, String)] = [
            (.apply(.init(state: .rootStack)), "apply"),
            (.windowScoped(windowID, .push(.home)), "windowScoped"),
            (.immersiveSpaceScoped("space", .push(.home)), "immersiveSpaceScoped"),
            (.openWindow(.init(id: windowID, route: .home)), "openWindow"),
            (.dismissWindow(windowID), "dismissWindow"),
            (
                .enterImmersiveSpace(.init(id: "space", route: .home)),
                "enterImmersiveSpace"
            ),
            (.dismissImmersiveSpace, "dismissImmersiveSpace"),
        ]

        for (action, name) in actions {
            #expect(throws: RouterFeatureProjectionError.globalActionNotAllowed(
                namespace: "Parent.primary",
                action: name
            )) {
                try mapping.embed(action)
            }
        }
    }
}
