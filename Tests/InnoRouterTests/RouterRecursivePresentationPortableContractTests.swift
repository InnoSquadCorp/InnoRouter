import Foundation
import Testing

import InnoRouterCore
import InnoRouterDeepLink

@Suite("Recursive presentation portable contracts")
struct RouterRecursivePresentationPortableContractTests {
    private enum R: String, Route, Codable {
        case home, detail, editor, confirmation, protectedDetail, sibling
    }

    private enum Parent: Route, Codable {
        case feature(R)
        case unrelated
    }

    private let outerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let innerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let missingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private var childPath: RouterScopePath { .root.appendingPresentation(outerID) }
    private var grandchildPath: RouterScopePath { childPath.appendingPresentation(innerID) }

    private func presented(child: RouterNode<R> = .stack()) throws -> RouterState<R> {
        try RouterState(root: .stack(path: [.home], presentation: .init(
            id: outerID, route: .editor, style: .sheet, node: child
        )))
    }

    private func nested() throws -> RouterState<R> {
        try presented(child: .stack(path: [.detail], presentation: .init(
            id: innerID, route: .confirmation, style: .popover,
            node: .stack(path: [.protectedDetail])
        )))
    }

    @Test("Child stack advances while its covered parent remains blocked")
    func childPushAndParentIsolation() throws {
        let initial = try presented()
        let action = RouterAction<R>.push(.detail).inScope(childPath)
        #expect(action == .presentationScoped(outerID, .push(.detail)))
        let result = try RouterReducer.reduce(action, from: initial)
        #expect(result.node(at: childPath) == .stack(path: [.detail]))
        guard case .stack(let root) = result.root else {
            Issue.record("Expected root stack")
            return
        }
        #expect(root.path == [.home])
        #expect(initial.node(at: childPath) == .stack())
        #expect(throws: RouterMutationError.blockedByPresentation(.root)) {
            try RouterReducer.reduce(.push(.sibling), from: result)
        }
        #expect(try RouterReducer.reduce(.pushIfNeeded(.detail).inScope(childPath), from: result) == result)
        #expect(try RouterReducer.reduce(.popToRoot.inScope(childPath), from: result) == initial)
    }

    @Test("Nested presentation actions target one exact child and preserve parents")
    func nestedChildAction() throws {
        let initial = try presented(child: .stack(path: [.detail]))
        let nested = try RouterReducer.reduce(.present(.init(
            id: innerID, route: .confirmation, style: .fullScreenCover
        )).inScope(childPath), from: initial)
        let result = try RouterReducer.reduce(.push(.protectedDetail).inScope(grandchildPath), from: nested)
        #expect(result.node(at: grandchildPath) == .stack(path: [.protectedDetail]))
        #expect(throws: RouterMutationError.blockedByPresentation(childPath)) {
            try RouterReducer.reduce(.popToRoot.inScope(childPath), from: result)
        }
        #expect(throws: RouterMutationError.presentationAlreadyActive(childPath)) {
            try RouterReducer.reduce(.present(.init(
                id: missingID, route: .editor, style: .sheet
            )).inScope(childPath), from: result)
        }
        #expect(try RouterReducer.reduce(.dismissPresentation.inScope(childPath), from: result) == initial)
    }

    @Test("Closing a parent removes all descendant state and rejects stale callbacks")
    func parentCloseRemovesDescendants() throws {
        let initial = try nested()
        let result = try RouterReducer.reduce(.dismissPresentation, from: initial)
        #expect(result == .rootStack(path: [.home]))
        #expect(result.node(at: childPath) == nil)
        #expect(result.node(at: grandchildPath) == nil)
        #expect(throws: RouterMutationError.presentationIdentityMismatch(
            scope: .root, expected: outerID, actual: nil
        )) {
            try RouterReducer.reduce(.push(.detail).inScope(grandchildPath), from: result)
        }
        #expect(initial.node(at: grandchildPath) == .stack(path: [.protectedDetail]))
    }

    @Test("Branch and presentation boundaries are typed even when their labels match")
    func typedBoundaryLookupAndReplacement() throws {
        let id = RouterScopeID("presentation[\(outerID.uuidString)]")
        let root = try RouterContainerState<R>(style: .custom("root"), branches: [
            .init(id: id, node: .stack(path: [.sibling])),
            .init(id: "main", node: try nested().root),
        ])
        let initial = try RouterState(root: .container(root))
        let target = RouterScopePath(["main", .presentation(outerID), .presentation(innerID)])
        #expect(initial.node(at: [.branch(id)]) == .stack(path: [.sibling]))
        #expect(initial.node(at: [.presentation(outerID)]) == nil)
        #expect(initial.node(at: ["main", .branch(id)]) == nil)
        #expect(initial.node(at: target) == .stack(path: [.protectedDetail]))
        let result = try initial.replacingNode(.stack(path: [.confirmation]), at: target)
        #expect(result.node(at: target) == .stack(path: [.confirmation]))
        #expect(result.node(at: [.branch(id)]) == initial.node(at: [.branch(id)]))
        #expect(throws: RouterMutationError.presentationIdentityMismatch(
            scope: ["main"], expected: missingID, actual: outerID
        )) {
            try initial.replacingNode(.stack(), at: ["main", .presentation(missingID)])
        }
        #expect(throws: RouterMutationError.expectedStack(.root)) {
            try initial.replacingNode(.stack(), at: [.presentation(outerID)])
        }
    }

    @Test("Child requests cannot escape their presentation to perform global actions")
    func childCannotEscapeScope() throws {
        let initial = try nested()
        #expect(throws: RouterMutationError.scopedGlobalAction(grandchildPath)) {
            try RouterReducer.reduce(.openWindow(.init(
                id: missingID, route: .editor
            )).inScope(grandchildPath), from: initial)
        }
        #expect(throws: RouterMutationError.scopedGlobalAction(childPath)) {
            try RouterReducer.reduce(.apply(.init(state: .rootStack)).inScope(childPath), from: initial)
        }
        #expect(initial.node(at: grandchildPath) == .stack(path: [.protectedDetail]))
    }

    @Test("Modal container branches preserve sibling and scene state")
    func childContainerAndSceneIsolation() throws {
        let tabs = try RouterContainerState<R>(style: .tabs, selection: "left", branches: [
            .init(id: "left"), .init(id: "right", node: .stack(path: [.sibling])),
        ])
        let windowID = missingID
        let initial = try RouterState<R>(
            root: .stack(path: [.home]),
            windows: [.init(id: windowID, route: .editor, node: .stack(presentation: .init(
                id: outerID, route: .editor, style: .sheet, node: .container(tabs)
            )))],
            immersiveSpace: .init(id: "studio", route: .confirmation, node: .stack(presentation: .init(
                id: innerID, route: .editor, style: .sheet
            )))
        )
        let windowChild = RouterScopePath.window(windowID).appendingPresentation(outerID)
        let result = try RouterReducer.reduce(.push(.detail).inScope(windowChild.appending("left")), from: initial)
        #expect(result.root == initial.root)
        #expect(result.immersiveSpace == initial.immersiveSpace)
        #expect(result.node(at: windowChild.appending("right")) == .stack(path: [.sibling]))
        #expect(result.node(at: windowChild.appending("left")) == .stack(path: [.detail]))
        let immersionChild = RouterScopePath.immersiveSpace("studio").appendingPresentation(innerID)
        let immersiveResult = try RouterReducer.reduce(.push(.protectedDetail).inScope(immersionChild), from: result)
        #expect(immersiveResult.windows == result.windows)
        #expect(immersiveResult.node(at: immersionChild) == .stack(path: [.protectedDetail]))
    }

    @Test("Duplicate descendant presentation IDs fail construction and reducer admission")
    func duplicateDescendantIDs() throws {
        let repeated = RouterPresentation<R>(id: outerID, route: .confirmation, style: .sheet)
        #expect(throws: RouterStateValidationError.duplicatePresentation(outerID)) {
            try presented(child: .stack(presentation: repeated))
        }
        let initial = try presented()
        #expect(throws: RouterMutationError.invalidTargetState(.duplicatePresentation(outerID))) {
            try RouterReducer.reduce(.present(repeated).inScope(childPath), from: initial)
        }
        #expect(initial.node(at: childPath) == .stack())
        #expect(throws: RouterStateValidationError.duplicatePresentation(innerID)) {
            try RouterState(root: nested().root, windows: [.init(
                id: missingID, route: .home, node: .stack(presentation: .init(
                    id: innerID, route: .detail, style: .sheet
                ))
            )])
        }
    }

    @Test("Nested options are validated before a state can become authority")
    func nestedValidation() throws {
        var child = RouterPresentation<R>(id: innerID, route: .confirmation, style: .sheet)
        child.options.cornerRadius = -1
        #expect(throws: RouterStateValidationError.invalidPresentationCornerRadius(-1)) {
            try presented(child: .stack(presentation: child))
        }
    }

    @Test("Retained descendant identity cannot move or change payload")
    func descendantIdentityContinuity() throws {
        let initial = try nested()
        let changed = try presented(child: .stack(path: [.detail], presentation: .init(
            id: innerID, route: .sibling, style: .popover
        )))
        #expect(throws: RouterMutationError.presentationIdentityConflict(innerID)) {
            try RouterReducer.reduce(.apply(.init(state: changed)), from: initial)
        }
        let moved = try RouterState<R>(root: .stack(presentation: .init(
            id: innerID, route: .confirmation, style: .popover,
            node: .stack(path: [.protectedDetail])
        )))
        #expect(throws: RouterMutationError.presentationIdentityConflict(innerID)) {
            try RouterReducer.reduce(.apply(.init(state: moved)), from: initial)
        }
        let changedChild = try initial.replacingNode(.stack(path: [.sibling]), at: grandchildPath)
        #expect(try RouterReducer.reduce(.apply(.init(state: changedChild)), from: initial) == changedChild)
    }

    @Test("Plan builder uses typed presentation paths atomically")
    func planBuilder() throws {
        let initial = try presented()
        let plan = try RouterPlan(from: initial) {
            RouterPlanStep<R>.stack([.detail], at: childPath)
            RouterPlanStep<R>.presentation(.init(
                id: innerID, route: .confirmation, style: .popover
            ), at: childPath)
            RouterPlanStep<R>.stack([.protectedDetail], at: grandchildPath)
        }
        #expect(plan.state == (try nested()))
        #expect(initial.node(at: childPath) == .stack())
        #expect(try RouterReducer.reduce(.apply(plan), from: initial) == plan.state)
    }

    @Test("Legacy leaf Codable data defaults to an empty child without changing its encoding")
    func legacyLeafControl() throws {
        let data = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","route":"editor","style":"sheet"}
        """.utf8)
        let leaf = try JSONDecoder().decode(RouterPresentation<R>.self, from: data)
        let explicit = RouterPresentation<R>(id: outerID, route: .editor, style: .sheet, node: .stack())
        #expect(leaf == explicit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(leaf) == data)
        #expect(leaf.node == .stack())
    }

    @Test("Recursive state, typed paths, and child actions round trip exactly")
    func recursiveCodableRoundTrip() throws {
        let state = try nested()
        let action = RouterAction<R>.push(.detail).inScope(grandchildPath)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RouterState<R>.self, from: encoder.encode(state)) == state)
        #expect(try decoder.decode(RouterScopePath.self, from: encoder.encode(grandchildPath)) == grandchildPath)
        #expect(try decoder.decode(RouterAction<R>.self, from: encoder.encode(action)) == action)
        let legacyPath = Data(#"{"domain":{"application":{}},"components":[{"rawValue":"main"}]}"#.utf8)
        #expect(try decoder.decode(RouterScopePath.self, from: legacyPath) == ["main"])
    }

    @Test("Feature mapping preserves recursive topology, route ownership, and action parity")
    func featureMappingParity() throws {
        let mapping = RouterFeatureMapping<Parent, R>(id: "feature", namespace: "test", route: .init(
            embed: { .feature($0) }, extract: { if case .feature(let route) = $0 { route } else { nil } }
        ))
        let child = try nested()
        let embedded = try mapping.embed(child.root)
        #expect(try mapping.project(embedded) == child.root)
        let action = RouterAction<R>.push(.sibling).inScope(grandchildPath)
        let childResult = try RouterReducer.reduce(action, from: child)
        let parentResult = try RouterReducer.reduce(mapping.embed(action), from: RouterState(root: embedded))
        #expect(try mapping.project(parentResult.root) == childResult.root)
        let childPresentation = RouterPresentation<R>(
            id: missingID, route: .editor, style: .sheet, node: child.root
        )
        let childPresentResult = try RouterReducer.reduce(.present(childPresentation), from: .rootStack)
        let parentPresentResult = try RouterReducer.reduce(
            mapping.embed(.present(childPresentation)), from: RouterState<Parent>.rootStack
        )
        #expect(try mapping.project(parentPresentResult.root) == childPresentResult.root)
        let foreign = RouterNode<Parent>.stack(presentation: .init(
            id: outerID, route: .feature(.editor), style: .sheet, node: .stack(path: [.unrelated])
        ))
        #expect(throws: RouterFeatureProjectionError.routeMismatch(namespace: "test")) {
            try mapping.project(foreign)
        }
    }

    @Test("Authentication inspects protected descendant routes in every scene domain")
    func nestedAuthentication() async throws {
        let modal = try nested().root
        let states = [
            try RouterState(root: modal),
            try RouterState(root: .stack(), windows: [.init(id: missingID, route: .home, node: modal)]),
            try RouterState(root: .stack(), immersiveSpace: .init(id: "studio", route: .home, node: modal)),
        ]
        let url = try #require(URL(string: "router://app/nested"))
        for state in states {
            let plan = RouterPlan(state: state)
            for protectedRoute in [R.confirmation, .protectedDetail] {
                let pipeline = RouterLinkPipeline<R>(
                    originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
                    customResolver: { _ in plan },
                    authenticationPolicy: .required(
                        shouldRequireAuthentication: { $0 == protectedRoute }, isAuthenticated: { false }
                    )
                )
                #expect(await pipeline.decide(for: url) == .pending(.init(
                    url: url, gatedRoute: protectedRoute, plan: plan, isRevalidationRequired: true
                )))
            }
        }
    }
}
