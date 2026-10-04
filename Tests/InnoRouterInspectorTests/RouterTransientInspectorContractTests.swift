import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterInspector

@Suite("Transient presentation Inspector contracts")
struct RouterTransientInspectorContractTests {
    private enum R: Route { case home }

    @Test("Alert and dialog projections show structure without display or action payloads", arguments: [false, true])
    func redactedProjection(dialog: Bool) throws {
        let id = UUID()
        let transient = RouterTransientPresentation(id: id, content: .init(
            title: "SECRET-title", message: "SECRET-message", actions: [
                .init(id: "SECRET-action", label: "SECRET-label", role: .destructive),
            ]
        ))
        let family: RouterPresentationFamily<R> = dialog ? .confirmationDialog(transient) : .alert(transient)
        let state = try RouterState(root: .stack(presentationFamily: family))
        let tree = RouterInspectorProjection.tree(from: state)
        #expect(tree.root.details["presentation"] == (dialog ? "confirmationDialog" : "alert"))
        #expect(tree.root.details["presentationActions"] == "1")
        #expect(tree.root.children.isEmpty)
        #expect(tree.flattenedNodes.count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
        #expect(!encoded.contains(id.uuidString))
        let formatter: RouterInspectorFormatter<RouterEvent<R>> = redactedRouterFormatter()
        let event = formatter(.committed(transitionID: .init(), before: .rootStack, after: state, revision: 1, context: .init()))
        #expect(event.metadata["after"] == "stacks=1,routes=0,presentations=1,windows=0,immersive=0")
    }

    @Test("Nested transient selection preview and diff match the pure reducer")
    func selectionPreview() throws {
        let parentID = UUID(), childID = UUID()
        let child = RouterTransientPresentation(id: childID, content: .init(title: "SECRET", actions: [.init(id: "SECRET-ID", label: "SECRET")]))
        let state = try RouterState<R>(root: .stack(presentation: .init(
            id: parentID, route: .home, style: .sheet,
            node: .stack(presentationFamily: .alert(child))
        )))
        let action = RouterAction<R>.selectPresentationAction(presentationID: childID, actionID: "SECRET-ID")
            .inScope(.root.appendingPresentation(parentID))
        let proposed = try RouterReducer.reduce(action, from: state)
        let transition = RouterTransition(id: .init(), action: action, initialState: state, proposedState: proposed, initialRevision: 3)
        let preview = RouterInspectorReplay.preview(transition)
        #expect(preview.status == .matchedProposal)
        #expect(preview.state == RouterInspectorProjection.tree(from: proposed))
        let diff = RouterInspectorProjection.diff(from: state, to: proposed)
        #expect(diff.changes.contains(.init(path: "/presentation", field: "presentation", before: "alert", after: "none")))
        let formatter: RouterInspectorFormatter<RouterEvent<R>> = redactedRouterFormatter()
        #expect(formatter(.started(transition)).metadata["action"] == "presentationScoped.selectPresentationAction")
        for json in [try JSONEncoder().encode(preview), try JSONEncoder().encode(diff)] {
            let text = String(decoding: json, as: UTF8.self)
            #expect(!text.contains("SECRET"))
            #expect(!text.contains(parentID.uuidString))
            #expect(!text.contains(childID.uuidString))
        }
    }
}
