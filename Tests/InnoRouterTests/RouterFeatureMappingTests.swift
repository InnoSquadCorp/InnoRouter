import Foundation
import Testing

import InnoRouterCore
import InnoRouterDeepLink
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

    private enum Child: Hashable, Route, Codable {
        case home
        case detail(Int)
        case nested(Grandchild)
    }

    private enum Grandchild: Hashable, Route, Codable {
        case home
        case detail
    }

    private enum Parent: Hashable, Route, Codable {
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

    private var nestedMapping: RouterFeatureMapping<Child, Grandchild> {
        .init(
            id: "nested",
            namespace: "Child.nested",
            route: .init(
                embed: Child.nested,
                extract: {
                    guard case .nested(let child) = $0 else { return nil }
                    return child
                }
            )
        )
    }

    @Test("A nested feature plan rejects when only its nearest owner is replaced")
    @MainActor
    func nestedFeaturePlanRejectsReplacedAncestor() async {
        let deferralID = RouterDeferralID()
        let store = RouterStore<Parent>(
            initialState: .rootStack(path: [.feature(.nested(.home))]),
            configuration: .init(policies: [
                RouterPolicy(name: "approve-nested-plan") { transition in
                    guard transition.context.resumedDeferral == nil,
                          case .apply = transition.action else { return .allow }
                    return .deferRequest(deferralID)
                },
            ])
        )
        let outer = RouterFeatureScope(parent: store.scope(), mapping: mapping)
        let nested = RouterFeatureScope(parent: outer, mapping: nestedMapping)

        guard case .deferred = await nested.perform(
            .apply(.init(state: .rootStack(path: [.detail])))
        ) else {
            Issue.record("Expected nested plan to defer")
            return
        }
        _ = await store.perform(.replaceStack([.feature(.home)]))
        let outcome = await store.resolveDeferred(
            deferralID,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        )

        guard case .rejected(_, _, let revision, .featureProjection(
            .routeMismatch(namespace: "Child.nested")
        )) = outcome else {
            Issue.record("Expected nearest nested owner rejection")
            return
        }
        #expect(revision == 1)
        #expect(store.state == .rootStack(path: [.feature(.home)]))
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

    @Test("A rebased feature plan preserves current siblings and scene inventory")
    @MainActor
    func deferredFeaturePlanRebasesOnlyItsSubtree() async throws {
        let featureID: RouterScopeID = "feature"
        let siblingID: RouterScopeID = "sibling"
        let root = try RouterContainerState<Parent>(
            style: .tabs,
            selection: featureID,
            branches: [
                .init(id: featureID, node: .stack(path: [.feature(.home)])),
                .init(id: siblingID, node: .stack(path: [.sibling])),
            ]
        )
        let deferralID = RouterDeferralID()
        let store = RouterStore(
            initialState: try RouterState(root: .container(root)),
            configuration: .init(policies: [
                RouterPolicy(name: "approve-feature-plan") { transition in
                    guard transition.context.resumedDeferral == nil,
                          case .apply = transition.action else { return .allow }
                    return .deferRequest(deferralID)
                },
            ])
        )
        let feature = RouterFeatureScope(
            parent: store.scope(at: [featureID]),
            mapping: mapping
        )

        guard case .deferred = await feature.perform(
            .apply(.init(state: .rootStack(path: [.detail(7)])))
        ) else {
            Issue.record("Expected feature plan deferral")
            return
        }
        _ = await store.perform(.push(.sibling).inScope([siblingID]))
        let windowID = UUID()
        _ = await store.perform(.openWindow(.init(id: windowID, route: .sibling)))

        guard case .applied = await store.resumeDeferred(
            deferralID,
            strategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected scoped rebase to apply")
            return
        }

        #expect(store.state.node(at: [featureID]) == .stack(path: [.feature(.detail(7))]))
        #expect(store.state.node(at: [siblingID]) == .stack(path: [.sibling, .sibling]))
        #expect(store.state.windows.map(\.id) == [windowID])
    }

    @Test("A feature plan requiring unchanged state rejects after sibling mutation")
    @MainActor
    func deferredFeaturePlanKeepsStrictRevisionContract() async throws {
        let featureID: RouterScopeID = "feature"
        let siblingID: RouterScopeID = "sibling"
        let root = try RouterContainerState<Parent>(
            style: .tabs,
            selection: featureID,
            branches: [
                .init(id: featureID, node: .stack(path: [.feature(.home)])),
                .init(id: siblingID, node: .stack(path: [.sibling])),
            ]
        )
        let deferralID = RouterDeferralID()
        let store = RouterStore(
            initialState: try RouterState(root: .container(root)),
            configuration: .init(policies: [
                RouterPolicy(name: "approval") { transition in
                    if transition.context.resumedDeferral == nil,
                       case .apply = transition.action {
                        return .deferRequest(deferralID)
                    }
                    return .allow
                },
            ])
        )
        let feature = RouterFeatureScope(
            parent: store.scope(at: [featureID]),
            mapping: mapping
        )
        guard case .deferred = await feature.perform(
            .apply(.init(state: .rootStack(path: [.detail(3)])))
        ) else {
            Issue.record("Expected feature deferral")
            return
        }
        _ = await store.perform(.push(.sibling).inScope([siblingID]))

        guard case .rejected(_, _, _, .staleState(expectedRevision: 0, actualRevision: 1)) =
                await store.resumeDeferred(deferralID) else {
            Issue.record("Expected strict resume to reject the stale feature plan")
            return
        }
        #expect(store.state.node(at: [featureID]) == .stack(path: [.feature(.home)]))
        #expect(store.state.node(at: [siblingID]) == .stack(path: [.sibling, .sibling]))
    }

    @Test("A rebased feature plan rejects a subtree now owned by another feature")
    @MainActor
    func rebasedFeaturePlanRejectsReplacedOwner() async {
        let deferralID = RouterDeferralID()
        let store = RouterStore<Parent>(
            initialState: .rootStack(path: [.feature(.home)]),
            configuration: .init(policies: [
                RouterPolicy(name: "approval") { transition in
                    if transition.context.resumedDeferral == nil,
                       case .apply = transition.action {
                        return .deferRequest(deferralID)
                    }
                    return .allow
                },
            ])
        )
        let feature = RouterFeatureScope(parent: store.scope(), mapping: mapping)

        guard case .deferred = await feature.perform(
            .apply(.init(state: .rootStack(path: [.detail(3)])))
        ) else {
            Issue.record("Expected feature plan deferral")
            return
        }
        _ = await store.perform(.replaceStack([.sibling]))

        guard case .rejected(_, _, let revision, .featureProjection(
            .routeMismatch(namespace: "Parent.primary")
        )) = await store.resumeDeferred(deferralID, strategy: .rebaseOnCurrentState) else {
            Issue.record("Expected the replaced feature owner to reject the rebase")
            return
        }
        #expect(revision == 1)
        #expect(store.revision == 1)
        #expect(store.state == .rootStack(path: [.sibling]))
    }

    @Test("Feature rebase and pending-link cancellation retain separate request families")
    @MainActor
    func featureRebaseAndPendingLinkCancellationAreIsolated() async throws {
        let featureDeferral = RouterDeferralID()
        let linkDeferral = RouterDeferralID()
        let store = RouterStore<Parent>(
            initialState: .rootStack(path: [.feature(.home)]),
            configuration: .init(policies: [
                RouterPolicy(name: "separate-request-families") { transition in
                    guard transition.context.resumedDeferral == nil,
                          case .apply = transition.action else { return .allow }
                    return transition.context.source == .deepLink
                        ? .deferRequest(linkDeferral)
                        : .deferRequest(featureDeferral)
                },
            ])
        )
        let feature = RouterFeatureScope(parent: store.scope(), mapping: mapping)
        let link = PendingRouterLink<Parent>(
            url: try #require(URL(string: "innorouter://app/competing-request")),
            gatedRoute: .sibling,
            plan: .init(state: .rootStack(path: [.sibling]))
        )
        let slot = RouterPendingLinkSlot(link)

        guard case .deferred = await feature.perform(
            .apply(.init(state: .rootStack(path: [.detail(42)])))
        ), case .completed(_, .deferred) = await slot.resume(on: store) else {
            Issue.record("Expected both logical requests to defer independently")
            return
        }
        #expect(Set(store.deferredTransitions.map(\.id)) == [featureDeferral, linkDeferral])

        #expect(slot.cancel() == link)
        #expect(store.deferredTransitions.map(\.id) == [featureDeferral])
        guard case .applied = await store.resumeDeferred(
            featureDeferral,
            strategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected link cancellation to preserve the feature request family")
            return
        }

        #expect(store.state == .rootStack(path: [.feature(.detail(42))]))
        #expect(store.revision == 1)
        #expect(store.deferredTransitions.isEmpty)
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
