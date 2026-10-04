// InnoRouterCore - package-only, payload-free node-shape groundwork

/// An explicit renderer declaration, never inferred from a candidate state.
/// This value describes node kinds, ordered rendered branches and split roles.
/// It cannot prove matching view/root/label closures or route-to-host contracts
/// for presentations and scenes. It installs no Store or native-host policy.
///
/// Children are owned values, not references or named links: declaration cycles
/// are unrepresentable. Validation still bounds repeated children, metadata and
/// depth before any identifier hashing, and walks declarations iteratively.
package indirect enum RouterHostShapeContract: Sendable {
    case stack
    case tabs(branches: [RouterHostShapeBranch], extras: RouterHostExtraBranches)
    case splitTwo(sidebar: RouterHostShapeBranch, detail: RouterHostShapeBranch)
    case splitThree(sidebar: RouterHostShapeBranch, content: RouterHostShapeBranch, detail: RouterHostShapeBranch)
    case custom(declarationID: String, branches: [RouterHostShapeBranch], extras: RouterHostExtraBranches)
}

package struct RouterHostShapeBranch: Sendable {
    package let id: RouterScopeID
    package let shape: RouterHostShapeContract

    package init(_ id: RouterScopeID, shape: RouterHostShapeContract) {
        self.id = id
        self.shape = shape
    }
}

package enum RouterHostExtraBranches: Sendable {
    case reject
    /// Extra branches remain intact and structurally validated, but cannot be
    /// selected. No child renderer contract is claimed for those dormant nodes.
    case preserveDormant
}

/// Fixed code/detail vocabulary. Descriptions never interpolate Route values,
/// custom declaration names, identifier text or the underlying error message.
package struct RouterHostShapeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    package enum Code: String, Sendable {
        case resourceLimit = "hostShape.resourceLimit"
        case invalidDeclaration = "hostShape.invalidDeclaration"
        case invalidState = "hostShape.invalidState"
        case invalidScope = "hostShape.invalidScope"
        case missingScope = "hostShape.missingScope"
        case kindMismatch = "hostShape.kindMismatch"
        case missingBranch = "hostShape.missingBranch"
        case extraBranch = "hostShape.extraBranch"
        case branchOrderMismatch = "hostShape.branchOrderMismatch"
        case selectionNotRendered = "hostShape.selectionNotRendered"
        case splitMappingMismatch = "hostShape.splitMappingMismatch"
    }

    package enum Detail: Equatable, Sendable {
        case resource(RouterResourceLimitFailure)
        case emptyIdentifier
        case duplicateBranch
        case emptyTabs
        case stateStructure
        case nodeUnavailable
        case nodeKind
        case customDeclaration
        case declaredBranchUnavailable
        case undeclaredBranch
        case orderedBranches
        case selectedBranchUndeclared
        case splitColumns
    }

    package let code: Code
    package let scope: RouterScopePath
    package let detail: Detail
    package var description: String { code.rawValue }
}

package extension RouterHostShapeContract {
    /// Validates the entire input's resources/structure, then the node at the
    /// exact typed path against this explicit declaration. An unrelated invalid
    /// scene or dormant branch therefore still rejects the complete input.
    /// This read-only operation never reconciles, truncates or modifies input.
    ///
    /// Input state and declaration each use the supplied structural limits;
    /// declaration metadata includes its target path. Opaque Route storage is
    /// not measured or evaluated. Stack means only a stack node: a navigation
    /// presentation's child host is not inferred from its current child state.
    func validate<R: Route>(
        _ input: RouterStateDraft<R>,
        at scope: RouterScopePath,
        resourceBudget: RouterResourceBudget
    ) throws(RouterHostShapeFailure) {
        do {
            // All externally supplied structural input is admitted before the
            // state validator or declaration matcher can hash identifiers.
            try resourceBudget.validate(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
            try admitDeclaration(at: scope, limits: resourceBudget.snapshot)
        } catch {
            throw RouterHostShapeFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try validateScope(scope)
        try validateDeclaration(at: scope)
        let state: RouterState<R>
        do {
            state = try RouterState(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
        } catch {
            throw RouterHostShapeFailure(code: .invalidState, scope: .root, detail: .stateStructure)
        }
        guard let node = state.node(at: scope) else {
            throw RouterHostShapeFailure(code: .missingScope, scope: scope, detail: .nodeUnavailable)
        }
        var work = [(shape: self, node: node, scope: scope)]
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            try entry.shape.match(entry.node, at: entry.scope)
            guard case .container(let container) = entry.node else { continue }
            let actual = Dictionary(uniqueKeysWithValues: container.branches.map { ($0.id, $0.node) })
            for branch in entry.shape.branches {
                // match verified every declared branch exists before enqueueing.
                if let child = actual[branch.id] {
                    work.append((branch.shape, child, entry.scope.appending(branch.id)))
                }
            }
        }
    }
}

private extension RouterHostShapeContract {
    var branches: [RouterHostShapeBranch] {
        switch self {
        case .stack: []
        case .tabs(let branches, _), .custom(_, let branches, _): branches
        case .splitTwo(let sidebar, let detail): [sidebar, detail]
        case .splitThree(let sidebar, let content, let detail): [sidebar, content, detail]
        }
    }

    /// Resource preflight only. No equality, hashing, recursive calls, or
    /// construction of paths proportional to an unadmitted declaration.
    func admitDeclaration(
        at scope: RouterScopePath, limits: RouterGraphSnapshotLimits
    ) throws(RouterResourceLimitFailure) {
        func add(_ value: Int, _ increment: Int, maximum: Int, resource: String) throws(RouterResourceLimitFailure) -> Int {
            try RouterResourceBudget.addingResourceCount(value, increment, maximum: maximum, resource: resource)
        }
        let rootDepth = try add(scope.components.count, 1, maximum: limits.maximumGraphDepth, resource: "hostShape.depth")
        var bytes = 0
        func charge(_ value: String) throws(RouterResourceLimitFailure) {
            for _ in value.utf8 {
                bytes = try add(bytes, 1, maximum: limits.maximumPayloadBytes, resource: "hostShape.metadataBytes")
            }
        }
        if case .immersiveSpace(let id) = scope.domain { try charge(id) }
        for component in scope.components {
            if case .branch(let id) = component { try charge(id.rawValue) }
        }
        var work = [(shape: self, depth: rootDepth)]
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            if case .custom(let id, _, _) = entry.shape { try charge(id) }
            let branches = entry.shape.branches
            _ = try add(work.count, branches.count, maximum: limits.maximumNodes, resource: "hostShape.nodes")
            guard !branches.isEmpty else { continue }
            let depth = try add(entry.depth, 1, maximum: limits.maximumGraphDepth, resource: "hostShape.depth")
            for branch in branches {
                try charge(branch.id.rawValue)
                work.append((branch.shape, depth))
            }
        }
    }

    func validateScope(_ scope: RouterScopePath) throws(RouterHostShapeFailure) {
        if case .immersiveSpace(let id) = scope.domain, id.isEmpty {
            throw RouterHostShapeFailure(code: .invalidScope, scope: scope, detail: .emptyIdentifier)
        }
        for component in scope.components {
            if case .branch(let id) = component, id.rawValue.isEmpty {
                throw RouterHostShapeFailure(code: .invalidScope, scope: scope, detail: .emptyIdentifier)
            }
        }
    }

    func validateDeclaration(at scope: RouterScopePath) throws(RouterHostShapeFailure) {
        var work = [(shape: self, scope: scope)]
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            if case .custom(let id, _, _) = entry.shape, id.isEmpty {
                throw RouterHostShapeFailure(code: .invalidDeclaration, scope: entry.scope, detail: .emptyIdentifier)
            }
            let branches = entry.shape.branches
            if case .tabs = entry.shape, branches.isEmpty {
                throw RouterHostShapeFailure(code: .invalidDeclaration, scope: entry.scope, detail: .emptyTabs)
            }
            var ids: Set<RouterScopeID> = []
            for branch in branches {
                guard !branch.id.rawValue.isEmpty else {
                    throw RouterHostShapeFailure(code: .invalidDeclaration, scope: entry.scope, detail: .emptyIdentifier)
                }
                guard ids.insert(branch.id).inserted else {
                    throw RouterHostShapeFailure(code: .invalidDeclaration, scope: entry.scope, detail: .duplicateBranch)
                }
                work.append((branch.shape, entry.scope.appending(branch.id)))
            }
        }
    }

    func match<R: Route>(_ node: RouterNode<R>, at scope: RouterScopePath) throws(RouterHostShapeFailure) {
        func fail(_ code: RouterHostShapeFailure.Code, _ detail: RouterHostShapeFailure.Detail) -> RouterHostShapeFailure {
            RouterHostShapeFailure(code: code, scope: scope, detail: detail)
        }
        if case .stack = self {
            guard case .stack = node else { throw fail(.kindMismatch, .nodeKind) }
            return
        }
        guard case .container(let container) = node else { throw fail(.kindMismatch, .nodeKind) }
        let extras: RouterHostExtraBranches
        let matchesOrder: Bool
        switch (self, container.style) {
        case (.tabs(_, let policy), .tabs):
            extras = policy
            matchesOrder = true
        case (.custom(let expected, _, let policy), .custom(let actual)):
            guard expected == actual else { throw fail(.kindMismatch, .customDeclaration) }
            extras = policy
            matchesOrder = true
        case (.splitTwo(let sidebar, let detail), .split):
            guard let split = container.split, split.sidebar == sidebar.id,
                  split.content == nil, split.detail == detail.id else {
                throw fail(.splitMappingMismatch, .splitColumns)
            }
            extras = .reject
            matchesOrder = false
        case (.splitThree(let sidebar, let content, let detail), .split):
            guard let split = container.split, split.sidebar == sidebar.id,
                  split.content == content.id, split.detail == detail.id else {
                throw fail(.splitMappingMismatch, .splitColumns)
            }
            extras = .reject
            matchesOrder = false
        default:
            throw fail(.kindMismatch, .nodeKind)
        }
        let declared = branches.map(\.id)
        let rendered = Set(declared)
        let actual = Set(container.branches.map(\.id))
        for id in declared where !actual.contains(id) {
            throw RouterHostShapeFailure(code: .missingBranch, scope: scope.appending(id), detail: .declaredBranchUnavailable)
        }
        if let selection = container.selection, !rendered.contains(selection) {
            throw fail(.selectionNotRendered, .selectedBranchUndeclared)
        }
        if case .reject = extras, let extra = container.branches.first(where: { !rendered.contains($0.id) }) {
            throw RouterHostShapeFailure(code: .extraBranch, scope: scope.appending(extra.id), detail: .undeclaredBranch)
        }
        // Split role mapping determines rendered order independently of storage
        // order. Tabs/custom declare the ordered rendered subsequence explicitly.
        if matchesOrder, container.branches.map(\.id).filter({ rendered.contains($0) }) != declared {
            throw fail(.branchOrderMismatch, .orderedBranches)
        }
    }
}
