import InnoRouterCore

package extension PendingRouterLink {
    /// Re-admission may allocate fresh presentation/window instance IDs, but
    /// cannot change route payloads, navigation surface, selected declarations,
    /// presentation options, or the topology of a retained navigation intent.
    func matchesIntent(of request: RouterAdmittedLink<R>) -> Bool {
        if let matchedRoute, request.matchedRoute != matchedRoute { return false }
        let previous = plan.state
        let current = request.plan.state
        guard Self.sameNode(previous.root, current.root),
              previous.windows.count == current.windows.count else { return false }
        for (old, new) in zip(previous.windows, current.windows) {
            guard old.route == new.route, Self.sameNode(old.node, new.node) else { return false }
        }
        switch (previous.immersiveSpace, current.immersiveSpace) {
        case (.none, .none): return true
        case (.some(let old), .some(let new)):
            return old.id == new.id && old.route == new.route && Self.sameNode(old.node, new.node)
        default: return false
        }
    }

    private static func sameNode(_ old: RouterNode<R>, _ new: RouterNode<R>) -> Bool {
        switch (old, new) {
        case (.stack(let old), .stack(let new)):
            return old.path == new.path && samePresentation(old.presentationFamily, new.presentationFamily)
        case (.container(let old), .container(let new)):
            guard old.style == new.style, old.selection == new.selection,
                  old.badges == new.badges, old.split == new.split,
                  old.branches.map(\.id) == new.branches.map(\.id) else { return false }
            return zip(old.branches, new.branches).allSatisfy { sameNode($0.node, $1.node) }
        default: return false
        }
    }

    private static func samePresentation(_ old: RouterPresentationFamily<R>?, _ new: RouterPresentationFamily<R>?) -> Bool {
        switch (old, new) {
        case (.none, .none): return true
        case (.alert(let old), .alert(let new)), (.confirmationDialog(let old), .confirmationDialog(let new)):
            return old.content == new.content
        case (.navigation(let old), .navigation(let new)):
            return old.route == new.route && old.style == new.style
                && old.options == new.options && sameNode(old.node, new.node)
        default: return false
        }
    }
}
