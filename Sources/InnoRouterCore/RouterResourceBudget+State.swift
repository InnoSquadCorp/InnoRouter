import Foundation

public extension RouterResourceBudget {
    /// Checks resources iteratively before recursive structural validation.
    /// Counts match graph persistence: each domain root is a node, presentation
    /// edges increase both node depth and presentation depth, and scene roots
    /// contribute routes. No route codec or application callback is invoked.
    /// Validation has no lasting reservation and never truncates or mutates input.
    func validate<R: Route>(_ state: RouterState<R>) throws(RouterResourceLimitFailure) {
        try validate(root: state.root, windows: state.windows, immersiveSpace: state.immersiveSpace)
    }

    /// Validates resource use of mutable draft input before a RouterState exists.
    /// This does not replace identifier, selection or presentation validation.
    /// Repeated built-in name/ID UTF-8 bytes share `maximumPayloadBytes`; badge
    /// values and detent entries share `maximumJSONTokens`. They are accounted
    /// before later structural hashing, detent iteration or graph encoding.
    func validate<R: Route>(
        root: RouterNode<R>,
        windows: [RouterWindow<R>] = [],
        immersiveSpace: RouterImmersiveSpace<R>? = nil
    ) throws(RouterResourceLimitFailure) {
        try validateConfiguration()
        var metadata = RouterStateMetadataBudget(limits: snapshot)
        try validateStructure(root: root, windows: windows, immersiveSpace: immersiveSpace, metadata: &metadata)
    }

    /// Adds intent routes to the same aggregate count before application encoding.
    package func validate<R: Route>(_ state: RouterState<R>, additionalRouteCount: Int) throws(RouterResourceLimitFailure) {
        try validateConfiguration()
        var metadata = RouterStateMetadataBudget(limits: snapshot)
        try validateStructure(root: state.root, windows: state.windows, immersiveSpace: state.immersiveSpace,
                              metadata: &metadata, additionalRouteCount: additionalRouteCount)
    }

    private func validateStructure<R: Route>(
        root: RouterNode<R>,
        windows: [RouterWindow<R>] = [],
        immersiveSpace: RouterImmersiveSpace<R>? = nil,
        metadata: inout RouterStateMetadataBudget,
        additionalRouteCount: Int = 0
    ) throws(RouterResourceLimitFailure) {
        let limits = snapshot
        try check(windows.count, maximum: limits.maximumWindows, resource: "state.windows")
        var work: [(node: RouterNode<R>, depth: Int, presentations: Int)] = []
        var routes = try sum(0, additionalRouteCount, maximum: limits.maximumRoutes, resource: "state.routes")
        var presentations = 0
        func enqueue(_ node: RouterNode<R>, depth: Int = 1, modalDepth: Int = 0) throws(RouterResourceLimitFailure) {
            _ = try sum(work.count, 1, maximum: limits.maximumNodes, resource: "state.nodes")
            try check(depth, maximum: limits.maximumGraphDepth, resource: "state.graphDepth")
            try check(modalDepth, maximum: limits.maximumPresentationDepth, resource: "state.presentationDepth")
            // Keep processed entries so work.count is the whole-state count,
            // not merely the current frontier. Admission precedes each append.
            work.append((node, depth, modalDepth))
        }
        try enqueue(root)
        for window in windows {
            routes = try sum(routes, 1, maximum: limits.maximumRoutes, resource: "state.routes")
            try enqueue(window.node)
        }
        if let immersiveSpace {
            try metadata.charge(immersiveSpace.id)
            routes = try sum(routes, 1, maximum: limits.maximumRoutes, resource: "state.routes")
            try enqueue(immersiveSpace.node)
        }
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            switch entry.node {
            case .stack(let stack):
                try check(stack.path.count, maximum: limits.maximumStackPath, resource: "state.stackPath")
                routes = try sum(routes, stack.path.count, maximum: limits.maximumRoutes, resource: "state.routes")
                if let presentation = stack.presentation {
                    presentations = try sum(presentations, 1, maximum: limits.maximumPresentations, resource: "state.presentations")
                    routes = try sum(routes, 1, maximum: limits.maximumRoutes, resource: "state.routes")
                    try metadata.chargeElements(presentation.options.detents.count)
                    if presentation.options.selectedDetent != nil { try metadata.chargeElements(1) }
                    if case .enabledUpThrough = presentation.options.backgroundInteraction {
                        try metadata.chargeElements(1)
                    }
                    try enqueue(presentation.node,
                                depth: try sum(entry.depth, 1, maximum: limits.maximumGraphDepth, resource: "state.graphDepth"),
                                modalDepth: try sum(entry.presentations, 1, maximum: limits.maximumPresentationDepth, resource: "state.presentationDepth"))
                }
            case .container(let container):
                // Reject oversized collections before iterating their members or
                // allowing recursive structural validation to hash identifiers.
                _ = try sum(work.count, container.branches.count, maximum: limits.maximumNodes, resource: "state.nodes")
                try metadata.chargeElements(container.badges.count)
                if case .custom(let name) = container.style { try metadata.charge(name) }
                if let selection = container.selection { try metadata.charge(selection.rawValue) }
                if let split = container.split {
                    try metadata.charge(split.sidebar.rawValue)
                    if let content = split.content { try metadata.charge(content.rawValue) }
                    try metadata.charge(split.detail.rawValue)
                }
                for branch in container.branches {
                    try metadata.charge(branch.id.rawValue)
                    try enqueue(branch.node,
                                depth: try sum(entry.depth, 1, maximum: limits.maximumGraphDepth, resource: "state.graphDepth"),
                                modalDepth: entry.presentations)
                }
                for scope in container.badges.keys { try metadata.charge(scope.rawValue) }
            }
        }
    }

    /// Bounds the request's own structure before recursive dispatch. This is not
    /// candidate admission: the owner must validate the current and complete next
    /// state, with the next check occurring before recursive structural validation.
    /// An outer scene selector changes domains without adding graph depth.
    /// Owners validate this immutable budget's configuration before admission.
    package func validateInput<R: Route>(_ action: RouterAction<R>) throws(RouterResourceLimitFailure) {
        var current = action
        var depth = 1
        var metadata = RouterStateMetadataBudget(limits: snapshot)
        switch current {
        case .windowScoped(_, let child):
            current = child
        case .immersiveSpaceScoped(let id, let child):
            try metadata.charge(id)
            current = child
        default:
            break
        }
        while true {
            switch current {
            case .scoped(let id, let child):
                try metadata.charge(id.rawValue)
                depth = try sum(depth, 1, maximum: snapshot.maximumGraphDepth, resource: "request.scopeDepth")
                current = child
            case .immersiveSpaceScoped(let id, let child):
                try metadata.charge(id)
                depth = try sum(depth, 1, maximum: snapshot.maximumGraphDepth, resource: "request.scopeDepth")
                current = child
            case .presentationScoped(_, let child), .windowScoped(_, let child):
                depth = try sum(depth, 1, maximum: snapshot.maximumGraphDepth, resource: "request.scopeDepth")
                current = child
            case .apply(let plan):
                try validateStructure(
                    root: plan.state.root, windows: plan.state.windows,
                    immersiveSpace: plan.state.immersiveSpace, metadata: &metadata
                )
                return
            case .pushMany(let path), .replaceStack(let path):
                try check(path.count, maximum: snapshot.maximumStackPath, resource: "state.stackPath")
                try check(path.count, maximum: snapshot.maximumRoutes, resource: "state.routes")
                return
            case .present(let presentation):
                try validateStructure(root: RouterNode<R>.stack(presentation: presentation), metadata: &metadata)
                return
            case .openWindow(let window):
                // Include the scene route and the unavoidable application root.
                try validateStructure(root: RouterNode<R>.stack(), windows: [window], metadata: &metadata)
                return
            case .enterImmersiveSpace(let space):
                try validateStructure(root: RouterNode<R>.stack(), immersiveSpace: space, metadata: &metadata)
                return
            case .select(let id), .setBadge(_, let id):
                try metadata.charge(id.rawValue)
                return
            default: return
            }
        }
    }

    /// Admits the replacement input and scope path before recursive replacement.
    /// The owner separately validates the entire resulting state afterward.
    package func validateReplacement<R: Route>(
        _ node: RouterNode<R>, at path: RouterScopePath
    ) throws(RouterResourceLimitFailure) {
        _ = try sum(path.components.count, 1, maximum: snapshot.maximumGraphDepth, resource: "request.scopeDepth")
        var metadata = RouterStateMetadataBudget(limits: snapshot)
        if case .immersiveSpace(let id) = path.domain { try metadata.charge(id) }
        for component in path.components {
            if case .branch(let id) = component { try metadata.charge(id.rawValue) }
        }
        try validateStructure(root: node, metadata: &metadata)
    }

    private func check(_ actual: Int, maximum: Int, resource: String) throws(RouterResourceLimitFailure) {
        guard actual <= maximum else {
            throw RouterResourceLimitFailure(resource: resource, actual: actual, maximum: maximum)
        }
    }

    private func sum(_ value: Int, _ increment: Int, maximum: Int, resource: String) throws(RouterResourceLimitFailure) -> Int {
        try Self.addingResourceCount(value, increment, maximum: maximum, resource: resource)
    }
}

/// Counts each occurrence, rather than deduplicating shared String storage. This
/// models persisted metadata and bounds later hashing/validation input. It does
/// not measure allocator capacity, JSON escaping, Foundation internals, or Route.
private struct RouterStateMetadataBudget {
    let limits: RouterGraphSnapshotLimits
    private var bytes = 0
    private var elements = 0

    init(limits: RouterGraphSnapshotLimits) {
        self.limits = limits
    }

    mutating func charge(_ value: String) throws(RouterResourceLimitFailure) {
        // Stop at the first disallowed byte, even for a non-contiguous String;
        // do not allocate Data or traverse the remainder of an oversized value.
        for _ in value.utf8 {
            bytes = try RouterResourceBudget.addingResourceCount(
                bytes, 1, maximum: limits.maximumPayloadBytes, resource: "state.metadataBytes"
            )
        }
    }

    mutating func chargeElements(_ count: Int) throws(RouterResourceLimitFailure) {
        elements = try RouterResourceBudget.addingResourceCount(
            elements, count, maximum: limits.maximumJSONTokens, resource: "state.metadataElements"
        )
    }
}
