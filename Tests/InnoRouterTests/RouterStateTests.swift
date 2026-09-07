import Foundation
import Testing

import InnoRouterCore

@Suite("RouterState")
struct RouterStateTests {
    private enum RouteFixture: String, Route, Codable {
        case home
        case detail
        case settings
        case editor
    }

    @Test("Root stack actions produce one structurally valid state")
    func rootStackActions() throws {
        let initial = try RouterState<RouteFixture>()
        let pushed = try RouterReducer.reduce(.push(.detail), from: initial)
        let presented = try RouterReducer.reduce(
            .present(.init(route: .editor, style: .sheet)),
            from: pushed
        )

        #expect(pushed.root == .stack(path: [.detail]))
        guard case .stack(let stack) = presented.root else {
            Issue.record("Expected root stack")
            return
        }
        #expect(stack.path == [.detail])
        #expect(stack.presentation?.route == .editor)
        #expect(stack.presentation?.style == .sheet)
    }

    @Test("Presentation options survive Codable round trips")
    func presentationOptionsRoundTrip() throws {
        let state = try RouterState<RouteFixture>(
            root: .stack(
                presentation: .init(
                    route: .editor,
                    style: .popover,
                    options: .init(
                        detents: [.medium, .fraction(0.8)],
                        selectedDetent: .medium,
                        dragIndicator: .visible,
                        isInteractiveDismissDisabled: true,
                        compactAdaptation: .popover,
                        backgroundInteraction: .enabledUpThrough(.medium),
                        contentInteraction: .scrolls,
                        cornerRadius: 24
                    )
                )
            )
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RouterState<RouteFixture>.self, from: data)

        #expect(decoded == state)
    }

    @Test("Selected presentation detent is canonical state")
    func selectedPresentationDetent() throws {
        let initial = try RouterState<RouteFixture>(
            root: .stack(
                presentation: .init(
                    route: .editor,
                    style: .sheet,
                    options: .init(
                        detents: [.medium, .large],
                        selectedDetent: .medium
                    )
                )
            )
        )

        let next = try RouterReducer.reduce(.setPresentationDetent(.large), from: initial)
        guard case .stack(let stack) = next.root else {
            Issue.record("Expected stack")
            return
        }
        #expect(stack.presentation?.options.selectedDetent == .large)
        #expect(throws: RouterMutationError.unavailablePresentationDetent(.height(200), scope: .root)) {
            try RouterReducer.reduce(.setPresentationDetent(.height(200)), from: initial)
        }
    }

    @Test("Scoped actions mutate only the selected branch")
    func scopedMutation() throws {
        let tabs = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "home",
            branches: [
                RouterBranch(id: "home"),
                RouterBranch(id: "settings"),
            ]
        )
        let initial = try RouterState(root: .container(tabs))

        let next = try RouterReducer.reduce(
            RouterAction.push(.detail).inScope("home"),
            from: initial
        )

        guard case .container(let container) = next.root else {
            Issue.record("Expected tab container")
            return
        }
        #expect(container.selection == "home")
        #expect(container.branches[0].node == .stack(path: [.detail]))
        #expect(container.branches[1].node == .stack())
    }

    @Test("Idempotent stack actions are atomic reducer operations")
    func idempotentStackActions() throws {
        let initial = RouterState<RouteFixture>.rootStack(
            path: [.home, .detail, .settings]
        )
        let popped = try RouterReducer.reduce(.backOrPush(.detail), from: initial)
        let unchanged = try RouterReducer.reduce(.pushIfNeeded(.detail), from: popped)
        let replaced = try RouterReducer.reduce(.replaceTop(.editor), from: unchanged)
        let pushed = try RouterReducer.reduce(.backOrPush(.settings), from: replaced)

        #expect(popped.root == .stack(path: [.home, .detail]))
        #expect(unchanged == popped)
        #expect(replaced.root == .stack(path: [.home, .editor]))
        #expect(pushed.root == .stack(path: [.home, .editor, .settings]))
    }

    @Test("Invalid scoped mutation reports its exact parent path")
    func missingScope() throws {
        let tabs = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home")]
        )
        let initial = try RouterState(root: .container(tabs))

        #expect(throws: RouterMutationError.missingScope("profile", parent: .root)) {
            try RouterReducer.reduce(
                RouterAction.push(.detail).inScope("profile"),
                from: initial
            )
        }
    }

    @Test("Presentation makes stack progression impossible until dismissal")
    func presentationBlocksStackProgression() throws {
        let initial = try RouterState<RouteFixture>(
            root: .stack(
                path: [.detail],
                presentation: .init(route: .editor, style: .fullScreenCover)
            )
        )

        #expect(throws: RouterMutationError.blockedByPresentation(.root)) {
            try RouterReducer.reduce(.push(.settings), from: initial)
        }

        let dismissed = try RouterReducer.reduce(.dismissPresentation, from: initial)
        let next = try RouterReducer.reduce(.push(.settings), from: dismissed)
        #expect(next.root == .stack(path: [.detail, .settings]))
    }

    @Test("Pop rejects counts larger than the target stack depth")
    func invalidPopCount() throws {
        let initial = RouterState<RouteFixture>.rootStack(path: [.detail])

        #expect(
            throws: RouterMutationError.invalidPopCount(
                requested: 2,
                available: 1,
                scope: .root
            )
        ) {
            try RouterReducer.reduce(.pop(count: 2), from: initial)
        }
    }

    @Test("Whole-app plan includes regular and immersive destinations")
    func globalDestinations() throws {
        let initial = try RouterState<RouteFixture>()
        let windowID = UUID()
        let withWindow = try RouterReducer.reduce(
            .openWindow(.init(id: windowID, route: .editor)),
            from: initial
        )
        let withImmersive = try RouterReducer.reduce(
            .enterImmersiveSpace(.init(id: "studio", route: .detail)),
            from: withWindow
        )

        #expect(withImmersive.windows.map(\.id) == [windowID])
        #expect(withImmersive.immersiveSpace?.id == "studio")
        #expect(withImmersive.immersiveSpace?.route == .detail)
    }

    @Test("Window and immersive scopes own independent navigation trees")
    func sceneScopedNavigation() throws {
        let windowID = UUID()
        let initial = try RouterState<RouteFixture>(
            root: .stack(path: [.home]),
            windows: [.init(id: windowID, route: .editor)],
            immersiveSpace: .init(id: "studio", route: .detail)
        )

        let windowPath = RouterScopePath.window(windowID)
        let windowPushed = try RouterReducer.reduce(
            RouterAction.push(.settings).inScope(windowPath),
            from: initial
        )
        let immersivePath = RouterScopePath.immersiveSpace("studio")
        let fullyPushed = try RouterReducer.reduce(
            RouterAction.push(.editor).inScope(immersivePath),
            from: windowPushed
        )

        #expect(fullyPushed.root == .stack(path: [.home]))
        #expect(fullyPushed.node(at: windowPath) == .stack(path: [.settings]))
        #expect(fullyPushed.node(at: immersivePath) == .stack(path: [.editor]))
        #expect(fullyPushed.sceneRootRoute(at: windowPath) == .editor)
        #expect(fullyPushed.sceneRootRoute(at: immersivePath) == .detail)
    }

    @Test("Scene-scoped actions reject stale native identities")
    func missingSceneScope() throws {
        let missingWindow = UUID()
        let initial = try RouterState<RouteFixture>()

        #expect(throws: RouterMutationError.windowNotFound(missingWindow)) {
            try RouterReducer.reduce(
                RouterAction.push(.detail).inScope(.window(missingWindow)),
                from: initial
            )
        }
        #expect(throws: RouterMutationError.immersiveSpaceNotFound("missing")) {
            try RouterReducer.reduce(
                RouterAction.push(.detail).inScope(.immersiveSpace("missing")),
                from: initial
            )
        }
    }

    @Test("Split columns own independent stacks and snapshot-safe layout state")
    func splitStateRoundTrip() throws {
        let splitState = try RouterSplitState(
            sidebar: "sidebar",
            content: "content",
            detail: "detail",
            visibility: .all,
            preferredCompactColumn: .content
        )
        let split = try RouterContainerState<RouteFixture>(
            style: .split,
            selection: "detail",
            branches: [
                RouterBranch(id: "sidebar", node: .stack(path: [.home])),
                RouterBranch(id: "content", node: .stack(path: [.detail])),
                RouterBranch(id: "detail", node: .stack(path: [.editor])),
            ],
            split: splitState
        )
        let state = try RouterState(root: .container(split))
        let pushed = try RouterReducer.reduce(
            RouterAction.push(.settings).inScope("content"),
            from: state
        )
        let compact = try RouterReducer.reduce(
            .setPreferredCompactColumn(.sidebar),
            from: pushed
        )
        let detailOnly = try RouterReducer.reduce(
            .setSplitVisibility(.detailOnly),
            from: compact
        )

        guard case .container(let container) = detailOnly.root else {
            Issue.record("Expected split container")
            return
        }
        #expect(container.branches[0].node == .stack(path: [.home]))
        #expect(container.branches[1].node == .stack(path: [.detail, .settings]))
        #expect(container.branches[2].node == .stack(path: [.editor]))
        #expect(container.split?.visibility == .detailOnly)
        #expect(container.split?.preferredCompactColumn == .sidebar)

        let data = try JSONEncoder().encode(detailOnly)
        let decoded = try JSONDecoder().decode(RouterState<RouteFixture>.self, from: data)
        #expect(decoded == detailOnly)
    }

    @Test("Two-column split rejects an unavailable compact content column")
    func unavailableSplitColumn() throws {
        #expect(throws: RouterStateValidationError.unavailableSplitColumn(.content)) {
            _ = try RouterSplitState(
                sidebar: "sidebar",
                detail: "detail",
                preferredCompactColumn: .content
            )
        }
    }

    @Test("Split topology rejects branches that are not native columns")
    func unexpectedSplitBranch() throws {
        let splitState = try RouterSplitState(
            sidebar: "sidebar",
            detail: "detail"
        )

        #expect(throws: RouterStateValidationError.unexpectedSplitColumnScope("hidden")) {
            _ = try RouterContainerState<RouteFixture>(
                style: .split,
                branches: [
                    RouterBranch(id: "sidebar"),
                    RouterBranch(id: "detail"),
                    RouterBranch(id: "hidden"),
                ],
                split: splitState
            )
        }
    }

    @Test("A retained window identity cannot change its route")
    func windowIdentityContinuity() throws {
        let id = UUID()
        let initial = try RouterState<RouteFixture>(
            windows: [.init(id: id, route: .editor)]
        )
        let changed = try RouterState<RouteFixture>(
            windows: [.init(id: id, route: .detail)]
        )

        #expect(throws: RouterMutationError.windowIdentityConflict(id)) {
            _ = try RouterReducer.reduce(
                .apply(RouterPlan(state: changed)),
                from: initial
            )
        }
    }

    @Test("Codable round trip preserves the complete navigation tree")
    func codableRoundTrip() throws {
        let tabs = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "home",
            branches: [
                RouterBranch(id: "home", node: .stack(path: [.detail])),
                RouterBranch(id: "settings"),
            ]
        )
        let state = try RouterState(
            root: .container(tabs),
            windows: [.init(route: .editor)],
            immersiveSpace: .init(id: "studio", route: .home)
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RouterState<RouteFixture>.self, from: data)

        #expect(decoded == state)
    }

    @Test("Mutated badge state cannot bypass container invariants")
    func invalidBadges() throws {
        var container = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home")]
        )
        container.badges["missing"] = 1
        var state = try RouterState<RouteFixture>()
        state.root = .container(container)

        #expect(throws: RouterStateValidationError.unknownBadgeScope("missing")) {
            try state.validate()
        }
        #expect(
            throws: RouterMutationError.invalidTargetState(
                .unknownBadgeScope("missing")
            )
        ) {
            try RouterReducer.reduce(.apply(RouterPlan(state: state)), from: .rootStack)
        }

        container.badges = ["home": 0]
        state.root = .container(container)
        #expect(
            throws: RouterStateValidationError.invalidBadgeCount(
                scope: "home",
                count: 0
            )
        ) {
            try state.validate()
        }
    }

    @Test("Tab containers require a branch and an explicit selection")
    func tabContainerInvariants() throws {
        #expect(
            throws: RouterStateValidationError.emptyContainer(style: .tabs)
        ) {
            _ = try RouterContainerState<RouteFixture>(
                style: .tabs,
                branches: []
            )
        }
        #expect(
            throws: RouterStateValidationError.selectionRequired(style: .tabs)
        ) {
            _ = try RouterContainerState<RouteFixture>(
                style: .tabs,
                branches: [RouterBranch(id: "home")]
            )
        }
    }

    @Test("Presentation identifiers are unique across the complete tree")
    func presentationIdentifiersAreUnique() throws {
        let presentationID = UUID()
        let presentation = RouterPresentation(
            id: presentationID,
            route: RouteFixture.editor,
            style: .sheet
        )
        let tabs = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "home",
            branches: [
                RouterBranch(
                    id: "home",
                    node: .stack(presentation: presentation)
                ),
                RouterBranch(
                    id: "settings",
                    node: .stack(presentation: presentation)
                ),
            ]
        )

        #expect(
            throws: RouterStateValidationError.duplicatePresentation(presentationID)
        ) {
            _ = try RouterState(root: .container(tabs))
        }
    }

    @Test("Presentation identifiers are unique across application and scene trees")
    func scenePresentationIdentifiersAreUnique() throws {
        let presentationID = UUID()
        let presentation = RouterPresentation(
            id: presentationID,
            route: RouteFixture.editor,
            style: .sheet
        )

        #expect(
            throws: RouterStateValidationError.duplicatePresentation(presentationID)
        ) {
            _ = try RouterState<RouteFixture>(
                root: .stack(presentation: presentation),
                windows: [
                    .init(route: .editor, node: .stack(presentation: presentation))
                ]
            )
        }
    }

    @Test("Immersive space identifiers cannot be empty")
    func immersiveSpaceIdentifierIsRequired() {
        #expect(throws: RouterStateValidationError.emptyImmersiveSpaceID) {
            _ = try RouterState<RouteFixture>(
                immersiveSpace: .init(id: "", route: .editor)
            )
        }
    }

    @Test("An active presentation identity cannot move or change payload")
    func presentationIdentityContinuity() throws {
        let presentationID = UUID()
        let initial = try RouterState<RouteFixture>(
            root: .stack(
                presentation: .init(
                    id: presentationID,
                    route: .editor,
                    style: .sheet
                )
            )
        )
        let changed = try RouterState<RouteFixture>(
            root: .stack(
                presentation: .init(
                    id: presentationID,
                    route: .settings,
                    style: .sheet
                )
            )
        )

        #expect(
            throws: RouterMutationError.presentationIdentityConflict(presentationID)
        ) {
            _ = try RouterReducer.reduce(
                .apply(RouterPlan(state: changed)),
                from: initial
            )
        }
    }

    @Test("Plan builder composes scoped and global changes into one exact state")
    func planBuilder() throws {
        let tabs = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "home",
            branches: [
                RouterBranch(id: "home"),
                RouterBranch(id: "settings"),
            ]
        )
        let base = try RouterState<RouteFixture>(root: .container(tabs))
        let window = RouterWindow(route: RouteFixture.editor)

        let plan = try RouterPlan(from: base) {
            RouterPlanStep.stack([.detail], at: ["home"])
            RouterPlanStep.select("settings")
            RouterPlanStep.windows([window])
            RouterPlanStep.immersiveSpace(.init(id: "studio", route: .editor))
        }

        guard case .container(let container) = plan.state.root else {
            Issue.record("Expected tab container")
            return
        }
        #expect(container.selection == "settings")
        #expect(container.branches[0].node == .stack(path: [.detail]))
        #expect(plan.state.windows == [window])
        #expect(plan.state.immersiveSpace?.id == "studio")
    }
}
