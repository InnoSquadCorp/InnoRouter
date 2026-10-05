import Foundation
import Testing

// Keep a normal import: these contracts exercise the public construction
// boundary without access to the core module's internal state setters.
import InnoRouterCore

@Suite("Validated RouterState draft contracts")
struct RouterStateDraftPortableContractTests {
    private enum R: String, Route, Codable {
        case home
        case detail
        case settings
        case editor
    }

    // Models untrusted serialized input without constructing invalid state.
    private struct StatePayload: Encodable {
        var root: RouterNode<R>
        var windows: [RouterWindow<R>] = []
        var immersiveSpace: RouterImmersiveSpace<R>?
    }

    @Test("Empty draft retains the simple root-stack convenience")
    func defaultDraft() throws {
        let state = try RouterStateDraft<R>().build()

        #expect(state == .rootStack)
        #expect(try RouterStateDraft(state).build() == state)
        #expect(try RouterReducer.reduce(.push(.detail), from: state) == .rootStack(path: [.detail]))
    }

    @Test("Complete recursive draft builds a plan and round trips through Codable")
    func completeDraftRoundTrip() throws {
        let nested = try tabs()
        let root = try RouterContainerState<R>(
            style: .custom("workspace"),
            branches: [.init(id: "navigation", node: .container(nested))]
        )
        let draft = RouterStateDraft<R>(
            root: .container(root),
            windows: [.init(route: .editor, node: .stack(path: [.detail]))],
            immersiveSpace: .init(id: "studio", route: .home)
        )
        let state = try draft.build()
        let plan = RouterPlan(state: state)
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RouterState<R>.self, from: encoded)

        #expect(decoded == state)
        #expect(plan.state == state)
        #expect(try RouterReducer.reduce(.apply(plan), from: .rootStack) == state)
        #expect(state.node(at: ["navigation", "home"]) == .stack(path: [.home]))
    }

    @Test("Nested invalid selection is rejected at build without changing input")
    func invalidNestedSelection() throws {
        var nested = try tabs()
        nested.selection = "missing"
        let outer = try RouterContainerState<R>(
            style: .custom("workspace"),
            branches: [.init(id: "navigation", node: .container(nested))]
        )
        let draft = RouterStateDraft<R>(root: .container(outer))
        let before = draft

        #expect(throws: RouterStateValidationError.missingSelection("missing")) {
            try draft.build()
        }
        #expect(draft == before)
    }

    @Test("Duplicate branch input can be corrected after a typed build failure")
    func invalidDraftCanBeRepaired() throws {
        var container = try tabs()
        container.branches.append(.init(id: "home"))
        var draft = RouterStateDraft<R>(root: .container(container))

        #expect(throws: RouterStateValidationError.duplicateScope) {
            try draft.build()
        }
        container.branches.removeLast()
        draft.root = .container(container)
        #expect(try draft.build() == RouterState(root: .container(tabs())))
    }

    @Test("Draft rejects badge entries outside its branch set")
    func invalidBadgeScope() throws {
        var container = try tabs()
        container.badges["missing"] = 1
        let draft = RouterStateDraft<R>(root: .container(container))

        #expect(throws: RouterStateValidationError.unknownBadgeScope("missing")) {
            try draft.build()
        }
    }

    @Test("Draft rejects duplicate window identifiers")
    func duplicateWindows() {
        let id = UUID()
        let draft = RouterStateDraft<R>(windows: [
            .init(id: id, route: .home),
            .init(id: id, route: .detail),
        ])

        #expect(throws: RouterStateValidationError.duplicateWindow) {
            try draft.build()
        }
    }

    @Test("Draft rejects empty immersive identifiers")
    func emptyImmersiveIdentifier() {
        let draft = RouterStateDraft<R>(immersiveSpace: .init(id: "", route: .editor))

        #expect(throws: RouterStateValidationError.emptyImmersiveSpaceID) {
            try draft.build()
        }
    }

    @Test("Presentation identity validation covers every scene domain")
    func duplicatePresentationAcrossDomains() {
        let presentation = RouterPresentation<R>(route: .editor, style: .sheet)
        let draft = RouterStateDraft<R>(
            root: .stack(presentation: presentation),
            windows: [.init(route: .home, node: .stack(presentation: presentation))]
        )

        #expect(throws: RouterStateValidationError.duplicatePresentation(presentation.id)) {
            try draft.build()
        }
    }

    @Test("Draft validates presentation options in scene-local subtrees")
    func invalidPresentationOptions() {
        let draft = RouterStateDraft<R>(immersiveSpace: .init(
            id: "studio",
            route: .home,
            node: .stack(presentation: .init(
                route: .editor,
                style: .sheet,
                options: .init(detents: [.fraction(1.5)])
            ))
        ))

        #expect(throws: RouterStateValidationError.invalidPresentationDetent(.fraction(1.5))) {
            try draft.build()
        }
    }

    @Test("Draft revalidates mutated split-column identifiers")
    func duplicateSplitColumns() throws {
        var split = try RouterSplitState()
        split.sidebar = split.detail
        var container = try RouterContainerState<R>(
            style: .custom("input"),
            branches: [.init(id: "detail")]
        )
        container.style = .split
        container.split = split
        let draft = RouterStateDraft<R>(root: .container(container))

        #expect(throws: RouterStateValidationError.duplicateSplitColumnScope) {
            try draft.build()
        }
    }

    @Test("Split initializer and decoded state reject duplicate column identifiers")
    func duplicateSplitColumnsAcrossConstructionPaths() throws {
        var split = try RouterSplitState()
        split.sidebar = split.detail
        #expect(throws: RouterStateValidationError.duplicateSplitColumnScope) {
            try RouterContainerState<R>(
                style: .split,
                branches: [.init(id: "detail")],
                split: split
            )
        }
        var container = try RouterContainerState<R>(
            style: .custom("input"),
            branches: [.init(id: "detail")]
        )
        container.style = .split
        container.split = split
        let data = try JSONEncoder().encode(StatePayload(root: .container(container)))
        #expect(throws: RouterStateValidationError.duplicateSplitColumnScope) {
            try JSONDecoder().decode(RouterState<R>.self, from: data)
        }
    }

    @Test("Split construction revalidates empty column identifiers")
    func emptySplitColumn() throws {
        var split = try RouterSplitState()
        split.sidebar = ""

        #expect(throws: RouterStateValidationError.emptyScope) {
            try RouterContainerState<R>(
                style: .split,
                branches: [.init(id: ""), .init(id: "detail")],
                split: split
            )
        }
    }

    @Test("Valid two-column and three-column drafts still build and round trip", arguments: [false, true])
    func validSplitColumns(threeColumns: Bool) throws {
        let split = try RouterSplitState(content: threeColumns ? "content" : nil)
        let scopes: [RouterScopeID] = threeColumns
            ? ["sidebar", "content", "detail"]
            : ["sidebar", "detail"]
        let container = try RouterContainerState<R>(
            style: .split,
            branches: scopes.map { .init(id: $0) },
            split: split
        )
        let state = try RouterStateDraft<R>(root: .container(container)).build()
        let data = try JSONEncoder().encode(state)

        #expect(try JSONDecoder().decode(RouterState<R>.self, from: data) == state)
    }

    @Test("Decoded state retains typed structural validation")
    func invalidDecodedState() throws {
        var container = try tabs()
        container.selection = "missing"
        let data = try JSONEncoder().encode(StatePayload(root: .container(container)))

        #expect(throws: RouterStateValidationError.missingSelection("missing")) {
            try JSONDecoder().decode(RouterState<R>.self, from: data)
        }
    }

    @Test("Copied drafts and observed nodes preserve independent value semantics")
    func independentCopies() throws {
        let original = try RouterState<R>(
            root: .container(tabs()),
            windows: [.init(route: .editor, node: .stack(path: [.home]))],
            immersiveSpace: .init(id: "studio", route: .home)
        )
        let first = RouterStateDraft(original)
        var second = first
        guard case .container(var observed) = original.root else {
            Issue.record("Expected tab root")
            return
        }
        observed.branches[0].node = .stack(path: [.detail])
        observed.selection = "settings"
        second.root = .container(observed)
        second.windows[0].node = .stack(path: [.settings])
        second.immersiveSpace?.node = .stack(path: [.detail])
        let changed = try second.build()

        #expect(try first.build() == original)
        #expect(changed != original)
        #expect(original.node(at: ["home"]) == .stack(path: [.home]))
        #expect(original.windows[0].node == .stack(path: [.home]))
        #expect(original.immersiveSpace?.node == .stack())
        #expect(changed.node(at: ["home"]) == .stack(path: [.detail]))
    }

    @Test("Built state does not alias subsequent draft mutations")
    func independentBuiltValue() throws {
        var draft = RouterStateDraft<R>(root: .stack(path: [.home]))
        let built = try draft.build()
        draft.root = .stack(path: [.settings])
        draft.windows.append(.init(route: .editor))

        #expect(built == .rootStack(path: [.home]))
        #expect(try draft.build() != built)
    }

    @Test("Draft and built state cross concurrency boundaries as Sendable values")
    func sendableDraft() async throws {
        let draft = RouterStateDraft<R>(root: .stack(path: [.home]))
        let state = try await Task.detached { try draft.build() }.value

        #expect(state == .rootStack(path: [.home]))
    }

    @Test("Accepted and unchanged reducer results preserve siblings and scenes")
    func reducerSiblingControls() throws {
        let initial = try RouterStateDraft<R>(
            root: .container(tabs()),
            windows: [.init(route: .editor)],
            immersiveSpace: .init(id: "studio", route: .home)
        ).build()
        let changed = try RouterReducer.reduce(.push(.detail).inScope("home"), from: initial)
        let unchanged = try RouterReducer.reduce(.pushIfNeeded(.detail).inScope("home"), from: changed)

        #expect(changed.node(at: ["home"]) == .stack(path: [.home, .detail]))
        #expect(changed.node(at: ["settings"]) == initial.node(at: ["settings"]))
        #expect(changed.windows == initial.windows)
        #expect(changed.immersiveSpace == initial.immersiveSpace)
        #expect(initial.node(at: ["home"]) == .stack(path: [.home]))
        #expect(unchanged == changed)
    }

    @Test("Rejected reducer candidates do not leak partial scene changes")
    func rejectedReducerCandidateIsAtomic() throws {
        let window = RouterWindow<R>(route: .editor)
        let initial = try RouterStateDraft<R>(
            root: .container(tabs()),
            windows: [window]
        ).build()
        let before = initial

        #expect(throws: RouterMutationError.invalidTargetState(.duplicateWindow)) {
            try RouterReducer.reduce(.openWindow(window), from: initial)
        }
        #expect(initial == before)
        #expect(throws: RouterMutationError.missingScope("missing", parent: .root)) {
            try RouterReducer.reduce(.push(.detail).inScope("missing"), from: initial)
        }
        #expect(initial == before)
    }

    private func tabs() throws -> RouterContainerState<R> {
        try RouterContainerState(
            style: .tabs,
            selection: "home",
            branches: [
                .init(id: "home", node: .stack(path: [.home])),
                .init(id: "settings", node: .stack(path: [.settings])),
            ]
        )
    }
}
