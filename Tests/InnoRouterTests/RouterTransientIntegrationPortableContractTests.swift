import Foundation
import Testing

import InnoRouterCore
import InnoRouterDeepLink

@Suite("Transient presentation integration portable contracts")
struct RouterTransientIntegrationPortableContractTests {
    private enum R: String, Route, Codable { case home, detail, modal, scene }

    private let windowID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private var content: RouterTransientPresentationContent {
        .init(title: "Delete item?", message: "This cannot be undone.", actions: [
            .init(id: "delete", label: "Delete", role: .destructive),
            .init(id: "cancel", label: "Cancel", role: .cancel),
        ])
    }

    private func family(
        _ kind: Int, id: UUID = UUID(), content: RouterTransientPresentationContent? = nil
    ) -> RouterPresentationFamily<R> {
        if kind == 0 { return .navigation(.init(id: id, route: .modal, style: .sheet)) }
        let value = RouterTransientPresentation(id: id, content: content ?? self.content)
        return kind == 1 ? .alert(value) : .confirmationDialog(value)
    }

    private func state(
        _ family: RouterPresentationFamily<R>?, in domain: Int
    ) throws -> RouterState<R> {
        let node = RouterNode<R>.stack(path: [.home], presentationFamily: family)
        switch domain {
        case 0: return try .init(root: node)
        case 1: return try .init(windows: [.init(id: windowID, route: .scene, node: node)])
        default: return try .init(immersiveSpace: .init(id: "studio", route: .scene, node: node))
        }
    }

    private func scope(_ domain: Int) -> RouterScopePath {
        switch domain {
        case 0: .root
        case 1: .window(windowID)
        default: .immersiveSpace("studio")
        }
    }

    @Test("Pending intent permits only presentation instance reallocation", arguments: [1, 2], 0..<3)
    func pendingIntent(kind: Int, domain: Int) throws {
        let original = family(kind)
        let pending = PendingRouterLink(
            url: URL(string: "https://example.com/item")!, gatedRoute: R.home,
            plan: .init(state: try state(original, in: domain)), matchedRoute: .home,
            isRevalidationRequired: true
        )
        func matches(_ family: RouterPresentationFamily<R>?) throws -> Bool {
            pending.matchesIntent(of: .init(plan: .init(state: try state(family, in: domain)), matchedRoute: .home))
        }
        #expect(try matches(original))
        let reallocated = family(kind)
        #expect(reallocated.id != original.id)
        #expect(try matches(reallocated))
        #expect(try !matches(nil))
        #expect(try !matches(family(0, id: original.id)))
        #expect(try !matches(family(kind == 1 ? 2 : 1, id: original.id)))

        let actions = content.actions
        let changes: [RouterTransientPresentationContent] = [
            .init(title: "Different title", message: content.message, actions: actions),
            .init(title: content.title, message: "Different message", actions: actions),
            .init(title: content.title, actions: actions),
            .init(title: content.title, message: content.message, actions: [
                .init(id: "different", label: actions[0].label, role: actions[0].role), actions[1],
            ]),
            .init(title: content.title, message: content.message, actions: [
                .init(id: actions[0].id, label: "Different label", role: actions[0].role), actions[1],
            ]),
            .init(title: content.title, message: content.message, actions: [
                .init(id: actions[0].id, label: actions[0].label, role: .normal), actions[1],
            ]),
            .init(title: content.title, message: content.message, actions: Array(actions.reversed())),
            .init(title: content.title, message: content.message, actions: [actions[0]]),
            .init(title: content.title, message: content.message, actions: actions + [.init(id: "help", label: "Help")]),
        ]
        for changed in changes {
            // Each candidate is independently valid, so failure proves intent
            // comparison rather than rejection by structural admission.
            #expect(try !matches(family(kind, id: original.id, content: changed)))
            #expect(try !matches(family(kind, content: changed)))
        }
    }

    @Test("Presentation IDs remain unique across application, window and immersive domains", arguments: 0..<3, 0..<3)
    func crossDomainDuplicateIdentity(first: Int, second: Int) throws {
        let id = UUID()
        for domains in [(0, 1), (0, 2), (1, 2)] {
            let initial = try state(family(first, id: id), in: domains.0)
            let duplicate = RouterNode<R>.stack(presentationFamily: family(second, id: id))
            let unique = RouterNode<R>.stack(presentationFamily: family(second))
            let duplicateAction: RouterAction<R> = domains.1 == 1
                ? .openWindow(.init(id: windowID, route: .scene, node: duplicate))
                : .enterImmersiveSpace(.init(id: "studio", route: .scene, node: duplicate))
            let uniqueAction: RouterAction<R> = domains.1 == 1
                ? .openWindow(.init(id: windowID, route: .scene, node: unique))
                : .enterImmersiveSpace(.init(id: "studio", route: .scene, node: unique))

            #expect(throws: RouterMutationError.invalidTargetState(.duplicatePresentation(id))) {
                try RouterReducer.reduce(duplicateAction, from: initial)
            }
            let accepted = try RouterReducer.reduce(uniqueAction, from: initial)
            #expect(accepted.node(at: scope(domains.0)) == initial.node(at: scope(domains.0)))
            #expect(accepted.node(at: scope(domains.1)) == unique)
            #expect(throws: RouterStateValidationError.duplicatePresentation(id)) {
                try RouterState(
                    root: initial.root,
                    windows: domains.1 == 1 ? [.init(id: windowID, route: .scene, node: duplicate)] : initial.windows,
                    immersiveSpace: domains.1 == 2 ? .init(id: "studio", route: .scene, node: duplicate) : nil
                )
            }
        }
    }

    @Test("Transient IDs cannot navigate or replace a fabricated child in any domain", arguments: [1, 2], 0..<3)
    func noTransientChild(kind: Int, domain: Int) throws {
        let presentation = family(kind)
        let initial = try state(presentation, in: domain)
        let owner = scope(domain)
        for requestedID in [presentation.id, UUID()] {
            let child = owner.appendingPresentation(requestedID)
            let failure = RouterMutationError.presentationIdentityMismatch(
                scope: owner, expected: requestedID, actual: presentation.id
            )
            #expect(initial.node(at: child) == nil)
            #expect(throws: failure) {
                try RouterReducer.reduce(.push(.detail).inScope(child), from: initial)
            }
            #expect(throws: failure) {
                try initial.replacingNode(.stack(path: [.detail]), at: child)
            }
        }
        #expect(initial.node(at: owner) == .stack(path: [.home], presentationFamily: presentation))
        // The same path shape remains valid for a real navigation presentation.
        let navigation = try state(family(0, id: presentation.id), in: domain)
        let realChild = owner.appendingPresentation(presentation.id)
        #expect(try navigation.replacingNode(.stack(path: [.detail]), at: realChild).node(at: realChild) == .stack(path: [.detail]))
    }

    @Test("History projection intentionally drops all families in every domain")
    func historyProjection() throws {
        let navigation = RouterPresentation<R>(route: .modal, style: .sheet, node: .stack(presentationFamily: family(1)))
        let root = try RouterContainerState<R>(style: .tabs, selection: "alert", branches: [
            .init(id: "navigation", node: .stack(path: [.home], presentation: navigation)),
            .init(id: "alert", node: .stack(path: [.detail], presentationFamily: family(1))),
            .init(id: "dialog", node: .stack(presentationFamily: family(2))),
        ], badges: ["dialog": 7])
        let initial = try RouterState(root: .container(root), windows: [
            .init(id: windowID, route: .scene, node: .stack(path: [.detail], presentationFamily: family(2))),
        ], immersiveSpace: .init(id: "studio", route: .scene, node: .stack(path: [.home], presentationFamily: family(1))))
        let expected = try RouterState<R>(root: .container(try .init(style: .tabs, selection: "alert", branches: [
            .init(id: "navigation", node: .stack(path: [.home])),
            .init(id: "alert", node: .stack(path: [.detail])), .init(id: "dialog"),
        ])), windows: [.init(id: windowID, route: .scene, node: .stack(path: [.detail]))],
            immersiveSpace: .init(id: "studio", route: .scene, node: .stack(path: [.home])))

        #expect(initial.navigationHistoryProjection() == expected)
        #expect(expected.navigationHistoryProjection() == expected)
        #expect(initial.root == .container(root))
        #expect(initial.node(at: ["navigation", .presentation(navigation.id)]) == navigation.node)
    }
}
