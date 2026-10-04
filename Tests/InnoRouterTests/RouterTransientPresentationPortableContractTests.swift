import Foundation
import Synchronization
import Testing

import InnoRouterCore

@Suite("Transient presentation portable contracts")
struct RouterTransientPresentationPortableContractTests {
    private enum R: String, Route, Codable { case home, child }

    private func transient(id: UUID = UUID(), title: String = "t") -> RouterTransientPresentation {
        .init(id: id, content: .init(title: title, actions: [.init(id: "a", label: "b")]))
    }

    private func family(_ kind: Int, id: UUID = UUID()) -> RouterPresentationFamily<R> {
        switch kind {
        case 0: .navigation(.init(id: id, route: .home, style: .sheet))
        case 1: .alert(transient(id: id))
        default: .confirmationDialog(transient(id: id))
        }
    }

    private func present(_ family: RouterPresentationFamily<R>) -> RouterAction<R> {
        switch family {
        case .navigation(let value): .present(value)
        case .alert(let value): .presentAlert(value)
        case .confirmationDialog(let value): .presentConfirmationDialog(value)
        }
    }

    @Test("Every presentation family conflicts with every already active family", arguments: 0..<3, 0..<3)
    func exclusiveFamilies(first: Int, second: Int) throws {
        let state = try RouterState(root: .stack(presentationFamily: family(first)))
        #expect(throws: RouterMutationError.presentationAlreadyActive(.root)) {
            try RouterReducer.reduce(present(family(second)), from: state)
        }
        #expect(throws: RouterMutationError.blockedByPresentation(.root)) {
            try RouterReducer.reduce(.push(.child), from: state)
        }
    }

    @Test("A child alert preserves its navigation parent and cannot invent a scope", arguments: [1, 2])
    func childTransient(kind: Int) throws {
        let parentID = UUID(), transientID = UUID()
        let parent = RouterPresentation<R>(id: parentID, route: .home, style: .sheet)
        let initial = try RouterState(root: .stack(presentation: parent))
        let childPath = RouterScopePath.root.appendingPresentation(parentID)
        let state = try RouterReducer.reduce(present(family(kind, id: transientID)).inScope(childPath), from: initial)
        #expect(state.node(at: childPath)?.presentationForTest == transientID)
        #expect(state.node(at: childPath.appendingPresentation(transientID)) == nil)
        #expect(throws: RouterMutationError.presentationIdentityMismatch(scope: childPath, expected: transientID, actual: transientID)) {
            try RouterReducer.reduce(.presentationScoped(parentID, .presentationScoped(transientID, .push(.child))), from: state)
        }
        let dismissed = try RouterReducer.reduce(.dismissPresentation.inScope(childPath), from: state)
        #expect(dismissed == initial)
    }

    @Test("IDs are globally unique across navigation and transient families", arguments: 0..<3, 0..<3)
    func duplicateIdentity(first: Int, second: Int) throws {
        let id = UUID()
        #expect(throws: RouterStateValidationError.duplicatePresentation(id)) {
            try RouterState<R>(root: .container(try .init(style: .tabs, selection: "left", branches: [
                .init(id: "left", node: .stack(presentationFamily: family(first, id: id))),
                .init(id: "right", node: .stack(presentationFamily: family(second, id: id))),
            ])))
        }
    }

    @Test("Retained logical ID cannot change family or immutable content", arguments: 0..<3)
    func identityContinuity(kind: Int) throws {
        let id = UUID()
        let initial = try RouterState(root: .stack(presentationFamily: family(kind, id: id)))
        let changedKind = try RouterState(root: .stack(presentationFamily: family((kind + 1) % 3, id: id)))
        #expect(throws: RouterMutationError.presentationIdentityConflict(id)) {
            try RouterReducer.reduce(.apply(.init(state: changedKind)), from: initial)
        }
        if kind > 0 {
            let changedContent: RouterPresentationFamily<R> = kind == 1
                ? .alert(transient(id: id, title: "changed")) : .confirmationDialog(transient(id: id, title: "changed"))
            let changed = try RouterState(root: .stack(presentationFamily: changedContent))
            #expect(throws: RouterMutationError.presentationIdentityConflict(id)) {
                try RouterReducer.reduce(.apply(.init(state: changed)), from: initial)
            }
        }
    }

    @Test("Invalid action declarations are typed payload-free failures", arguments: 0..<4)
    func invalidContent(index: Int) {
        let actions: [[RouterPresentationActionDescriptor]] = [
            [], [.init(id: "", label: "secret")],
            [.init(id: "a", label: "one"), .init(id: "a", label: "two")],
            [.init(id: "a", label: "one", role: .cancel), .init(id: "b", label: "two", role: .cancel)],
        ]
        let failures: [RouterTransientPresentationValidationFailure] = [.emptyActions, .emptyActionID, .duplicateActionID, .multipleCancelActions]
        let value = RouterTransientPresentation(content: .init(title: "secret", actions: actions[index]))
        #expect(throws: RouterMutationError.invalidTargetState(.invalidTransientPresentation(failures[index]))) {
            try RouterReducer.reduce(RouterAction<R>.presentAlert(value), from: .rootStack)
        }
    }

    @Test("Selection checks identity, family and declared action", arguments: [1, 2])
    func selection(kind: Int) throws {
        let value = family(kind), wrongID = UUID()
        let state = try RouterState(root: .stack(presentationFamily: value))
        #expect(throws: RouterMutationError.presentationIdentityMismatch(scope: .root, expected: wrongID, actual: value.id)) {
            try RouterReducer.reduce(.selectPresentationAction(presentationID: wrongID, actionID: "a"), from: state)
        }
        #expect(throws: RouterMutationError.unknownPresentationAction(.root)) {
            try RouterReducer.reduce(.selectPresentationAction(presentationID: value.id, actionID: "missing"), from: state)
        }
        #expect(throws: RouterMutationError.expectedNavigationPresentation(.root)) {
            try RouterReducer.reduce(.setPresentationDetent(.large), from: state)
        }
        #expect(try RouterReducer.reduce(.selectPresentationAction(presentationID: value.id, actionID: "a"), from: state) == .rootStack)
        let navigation = try RouterState(root: .stack(presentationFamily: family(0, id: value.id)))
        #expect(throws: RouterMutationError.expectedTransientPresentation(.root)) {
            try RouterReducer.reduce(.selectPresentationAction(presentationID: value.id, actionID: "a"), from: navigation)
        }
    }

    @Test("Clearing the navigation compatibility view leaves a transient active")
    func compatibilityView() {
        let value = family(1)
        var stack = RouterStackState<R>(presentationFamily: value)
        #expect(stack.presentation == nil)
        stack.presentation = nil
        #expect(stack.presentationFamily == value)
        stack.presentation = .init(route: .home, style: .sheet)
        #expect(stack.presentationFamily?.kind == .navigation)
        stack.presentation = nil
        #expect(stack.presentationFamily == nil)
    }

    @Test("Transient metadata is bounded and consumes no synthetic node or route")
    func resourceAccounting() throws {
        let state = try RouterState(root: .stack(path: [R.home], presentationFamily: family(1)))
        let exact = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 3, maximumNodes: 1, maximumRoutes: 1, maximumPresentations: 1, maximumGraphDepth: 1, maximumPresentationDepth: 1))
        try exact.validate(state)
        let small = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 2))
        #expect(throws: RouterResourceLimitFailure(resource: "state.metadataBytes", actual: 3, maximum: 2)) {
            try small.validate(state)
        }
        #expect(throws: RouterResourceLimitFailure.self) {
            try RouterReducer.reduce(RouterAction<R>.selectPresentationAction(presentationID: UUID(), actionID: "long"), from: .rootStack, resourceBudget: small)
        }
        let nested = try RouterState(root: .stack(presentation: .init(route: R.home, style: .sheet, node: .stack(presentationFamily: family(2)))))
        #expect(throws: RouterResourceLimitFailure(resource: "state.presentationDepth", actual: 2, maximum: 1)) {
            try RouterResourceBudget(snapshot: .init(maximumPresentationDepth: 1)).validate(nested)
        }
    }

    @Test("Feature projection and embedding preserve route-independent families")
    func featureParity() throws {
        let count = Mutex(0)
        let mapping = RouterFeatureMapping<R, R>(id: "identity", namespace: "identity", route: .init(embed: { route in count.withLock { $0 += 1 }; return route }, extract: { route in count.withLock { $0 += 1 }; return route }))
        let node = RouterNode<R>.stack(presentationFamily: family(2))
        #expect(try mapping.embed(node) == node)
        #expect(try mapping.project(node) == node)
        #expect(count.withLock { $0 } == 0)
        #expect(try mapping.embed(present(family(1))).presentationKindForTest == .alert)
    }

    @Test("Typed request values need neither Hashable nor Codable")
    func typedValues() {
        struct Value: Sendable { let evaluate: @Sendable () -> Int }
        let request = RouterTransientPresentationRequest<Value>.alert(title: "Title", actions: [
            .init(id: "accept", label: "Accept", value: Value(evaluate: { 7 })),
        ])
        #expect(request.actions.first?.value.evaluate() == 7)
    }

    @Test("Bare present actions cannot silently persist transient descriptors")
    func bareActionPersistence() {
        for kind in [1, 2] {
            let action = present(family(kind)).inScope("child")
            #expect(throws: RouterTransientPresentationPersistenceFailure.transientPresent) {
                try JSONEncoder().encode(action)
            }
        }
        #expect(throws: RouterTransientPresentationPersistenceFailure.unsupportedRestoration) {
            try JSONDecoder().decode(RouterAction<R>.self, from: Data(#"{"presentAlert":{"_0":{}}}"#.utf8))
        }
    }

    @Test("Action collections are admitted before duplicate identity hashing")
    func actionCountBeforeValidation() throws {
        let descriptor = RouterPresentationActionDescriptor(id: "same", label: "label")
        let value = RouterTransientPresentation(content: .init(title: "Title", actions: [descriptor, descriptor]))
        let budget = RouterResourceBudget(snapshot: try .init(maximumJSONTokens: 1))
        #expect(throws: RouterResourceLimitFailure(resource: "state.metadataElements", actual: 2, maximum: 1)) {
            try RouterReducer.reduce(RouterAction<R>.presentAlert(value), from: .rootStack, resourceBudget: budget)
        }
    }

    @Test("Exact plans preserve transient families and cannot move a retained owner")
    func planAndOwnerContinuity() throws {
        let value = family(1)
        let base = try RouterState<R>(root: .container(try .init(style: .tabs, selection: "left", branches: [
            .init(id: "left", node: .stack()), .init(id: "right", node: .stack()),
        ])))
        let plan = try RouterPlan(from: base) { RouterPlanStep<R>.presentationFamily(value, at: ["left"]) }
        #expect(plan.state.node(at: ["left"])?.presentationForTest == value.id)
        let moved = try RouterPlan(from: base) { RouterPlanStep<R>.presentationFamily(value, at: ["right"]) }
        #expect(throws: RouterMutationError.presentationIdentityConflict(value.id)) {
            try RouterReducer.reduce(.apply(moved), from: plan.state)
        }
        let sibling = try RouterReducer.reduce(.push(.child).inScope("right"), from: plan.state)
        #expect(sibling.node(at: ["left"]) == plan.state.node(at: ["left"]))
    }

    @Test("Navigation-only stack wire representation remains compatible")
    func legacyWire() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(RouterStackState<R>(path: [.home])), as: UTF8.self) == #"{"path":["home"]}"#)
        #expect(throws: RouterTransientPresentationPersistenceFailure.transientPresent) {
            try encoder.encode(RouterStackState<R>(presentationFamily: family(1)))
        }
        #expect(throws: RouterTransientPresentationPersistenceFailure.unsupportedRestoration) {
            try JSONDecoder().decode(RouterStackState<R>.self, from: Data(#"{"path":[],"alert":null}"#.utf8))
        }
    }
}

private extension RouterNode {
    var presentationForTest: UUID? {
        guard case .stack(let stack) = self else { return nil }
        return stack.presentationFamily?.id
    }
}

private extension RouterAction {
    var presentationKindForTest: RouterPresentationFamilyKind? {
        if case .presentAlert = self { return .alert }
        return nil
    }
}
