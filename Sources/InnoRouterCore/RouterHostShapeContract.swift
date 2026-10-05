// InnoRouterCore - explicit, payload-free host node shapes

/// An explicit renderer declaration, never inferred from a candidate state.
/// This value describes node kinds, ordered rendered branches and split roles.
/// It cannot prove matching view/root/label closures. Use
/// ``RouterHostDescriptor`` to additionally validate presentation and scene
/// catalogs. A shape by itself installs no Store or native-host policy.
///
/// Children are owned values, not references or named links: declaration cycles
/// are unrepresentable. Validation still bounds repeated children, metadata and
/// depth before any identifier hashing, and walks declarations iteratively.
public indirect enum RouterHostShape: Hashable, Sendable {
    case stack
    case tabs(branches: [RouterHostBranch], extras: RouterHostOrphanPolicy)
    case splitTwo(sidebar: RouterHostBranch, detail: RouterHostBranch)
    case splitThree(sidebar: RouterHostBranch, content: RouterHostBranch, detail: RouterHostBranch)
    case custom(declarationID: String, branches: [RouterHostBranch], extras: RouterHostOrphanPolicy)
}

public struct RouterHostBranch: Hashable, Sendable {
    public let id: RouterScopeID
    public let shape: RouterHostShape

    public init(_ id: RouterScopeID, shape: RouterHostShape) {
        self.id = id
        self.shape = shape
    }
}

public enum RouterHostOrphanPolicy: Hashable, Sendable {
    case reject
    /// Extra branches remain intact and structurally validated, but cannot be
    /// selected. No child renderer contract is claimed for those dormant nodes.
    case preserveDormant
}

/// Extensible error codes. Descriptions never interpolate Route values,
/// custom declaration names, identifier text or the underlying error message.
public struct RouterHostValidationFailure: Error, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Code: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let resourceLimit = Self(rawValue: "hostShape.resourceLimit")
        public static let invalidDeclaration = Self(rawValue: "hostShape.invalidDeclaration")
        public static let invalidState = Self(rawValue: "hostShape.invalidState")
        public static let invalidScope = Self(rawValue: "hostShape.invalidScope")
        public static let missingScope = Self(rawValue: "hostShape.missingScope")
        public static let kindMismatch = Self(rawValue: "hostShape.kindMismatch")
        public static let missingBranch = Self(rawValue: "hostShape.missingBranch")
        public static let extraBranch = Self(rawValue: "hostShape.extraBranch")
        public static let branchOrderMismatch = Self(rawValue: "hostShape.branchOrderMismatch")
        public static let selectionNotRendered = Self(rawValue: "hostShape.selectionNotRendered")
        public static let splitMappingMismatch = Self(rawValue: "hostShape.splitMappingMismatch")
        public static let required = Self(rawValue: "hostShape.required")
        public static let rendererMismatch = Self(rawValue: "hostShape.rendererMismatch")
        public static let stale = Self(rawValue: "hostShape.stale")
        public static let unknownDeclaration = Self(rawValue: "hostShape.unknownDeclaration")
        public static let duplicateDeclaration = Self(rawValue: "hostShape.duplicateDeclaration")
        public static let sceneIdentifierMismatch = Self(rawValue: "hostShape.sceneIdentifierMismatch")
    }

    package enum Detail: Hashable, Sendable {
        case unspecified
        case catalogDeclaration
        case sceneIdentifier
        case rendererDeclaration
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

    public let code: Code
    public let scope: RouterScopePath
    package let detail: Detail

    /// Structural resource information only; no route payload or resolver text.
    public var resourceLimit: RouterResourceLimitFailure? {
        if case .resource(let failure) = detail { failure } else { nil }
    }

    public init(code: Code, scope: RouterScopePath = .root, resourceLimit: RouterResourceLimitFailure? = nil) {
        self.code = code
        self.scope = scope
        self.detail = resourceLimit.map(Detail.resource) ?? .unspecified
    }

    package init(code: Code, scope: RouterScopePath, detail: Detail) {
        self.code = code
        self.scope = scope
        self.detail = detail
    }

    public var description: String { code.rawValue }
    public var debugDescription: String { description }
}

public extension RouterHostShape {
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
    ) throws(RouterHostValidationFailure) {
        do {
            // All externally supplied structural input is admitted before the
            // state validator or declaration matcher can hash identifiers.
            try resourceBudget.validate(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
            try admitDeclaration(at: scope, limits: resourceBudget.snapshot)
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try validateScope(scope)
        try validateDeclaration(at: scope)
        let state: RouterState<R>
        do {
            state = try RouterState(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
        } catch {
            throw RouterHostValidationFailure(code: .invalidState, scope: .root, detail: .stateStructure)
        }
        guard let node = state.node(at: scope) else {
            throw RouterHostValidationFailure(code: .missingScope, scope: scope, detail: .nodeUnavailable)
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

package extension RouterHostShape {
    var branches: [RouterHostBranch] {
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
        var admission = RouterHostDeclarationAdmission(limits: limits)
        try admission.admit(self, at: scope)
    }

    func validateScope(_ scope: RouterScopePath) throws(RouterHostValidationFailure) {
        if case .immersiveSpace(let id) = scope.domain, id.isEmpty {
            throw RouterHostValidationFailure(code: .invalidScope, scope: scope, detail: .emptyIdentifier)
        }
        for component in scope.components {
            if case .branch(let id) = component, id.rawValue.isEmpty {
                throw RouterHostValidationFailure(code: .invalidScope, scope: scope, detail: .emptyIdentifier)
            }
        }
    }

    func validateDeclaration(at scope: RouterScopePath) throws(RouterHostValidationFailure) {
        var work = [(shape: self, scope: scope)]
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            if case .custom(let id, _, _) = entry.shape, id.isEmpty {
                throw RouterHostValidationFailure(code: .invalidDeclaration, scope: entry.scope, detail: .emptyIdentifier)
            }
            let branches = entry.shape.branches
            if case .tabs = entry.shape, branches.isEmpty {
                throw RouterHostValidationFailure(code: .invalidDeclaration, scope: entry.scope, detail: .emptyTabs)
            }
            var ids: Set<RouterScopeID> = []
            for branch in branches {
                guard !branch.id.rawValue.isEmpty else {
                    throw RouterHostValidationFailure(code: .invalidDeclaration, scope: entry.scope, detail: .emptyIdentifier)
                }
                guard ids.insert(branch.id).inserted else {
                    throw RouterHostValidationFailure(code: .invalidDeclaration, scope: entry.scope, detail: .duplicateBranch)
                }
                work.append((branch.shape, entry.scope.appending(branch.id)))
            }
        }
    }

    func match<R: Route>(_ node: RouterNode<R>, at scope: RouterScopePath) throws(RouterHostValidationFailure) {
        func fail(_ code: RouterHostValidationFailure.Code, _ detail: RouterHostValidationFailure.Detail) -> RouterHostValidationFailure {
            RouterHostValidationFailure(code: code, scope: scope, detail: detail)
        }
        if case .stack = self {
            guard case .stack = node else { throw fail(.kindMismatch, .nodeKind) }
            return
        }
        guard case .container(let container) = node else { throw fail(.kindMismatch, .nodeKind) }
        let extras: RouterHostOrphanPolicy
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
            throw RouterHostValidationFailure(code: .missingBranch, scope: scope.appending(id), detail: .declaredBranchUnavailable)
        }
        if let selection = container.selection, !rendered.contains(selection) {
            throw fail(.selectionNotRendered, .selectedBranchUndeclared)
        }
        if case .reject = extras, let extra = container.branches.first(where: { !rendered.contains($0.id) }) {
            throw RouterHostValidationFailure(code: .extraBranch, scope: scope.appending(extra.id), detail: .undeclaredBranch)
        }
        // Split role mapping determines rendered order independently of storage
        // order. Tabs/custom declare the ordered rendered subsequence explicitly.
        if matchesOrder, container.branches.map(\.id).filter({ rendered.contains($0) }) != declared {
            throw fail(.branchOrderMismatch, .orderedBranches)
        }
    }
}

// Compatibility names for the package-only groundwork fixtures. New clients use
// the public descriptor vocabulary above.
package typealias RouterHostShapeContract = RouterHostShape
package typealias RouterHostShapeBranch = RouterHostBranch
package typealias RouterHostExtraBranches = RouterHostOrphanPolicy
package typealias RouterHostShapeFailure = RouterHostValidationFailure

/// One cumulative admission for the root and every frozen catalog entry. Charge
/// before hashing, comparing identifiers, invoking resolvers, or growing work.
package struct RouterHostDeclarationAdmission {
    let limits: RouterGraphSnapshotLimits
    private var nodes = 0
    private var bytes = 0

    init(limits: RouterGraphSnapshotLimits) { self.limits = limits }

    mutating func charge(_ value: String) throws(RouterResourceLimitFailure) {
        for _ in value.utf8 {
            bytes = try RouterResourceBudget.addingResourceCount(
                bytes, 1, maximum: limits.maximumPayloadBytes, resource: "hostShape.metadataBytes"
            )
        }
    }

    /// Root bindings are separate declaration records, cumulatively bounded
    /// before any relative path or semantic identifier is compared or hashed.
    mutating func admitRootDeclarations<R: Route>(
        _ declarations: [RouterHostRootDeclaration<R>], at scope: RouterScopePath
    ) throws(RouterResourceLimitFailure) {
        nodes = try RouterResourceBudget.addingResourceCount(
            nodes, declarations.count, maximum: limits.maximumNodes, resource: "hostShape.nodes"
        )
        for declaration in declarations {
            let depth = try RouterResourceBudget.addingResourceCount(
                scope.components.count, 1, maximum: limits.maximumGraphDepth, resource: "hostShape.depth"
            )
            _ = try RouterResourceBudget.addingResourceCount(
                depth, declaration.path.count, maximum: limits.maximumGraphDepth, resource: "hostShape.depth"
            )
            for id in declaration.path { try charge(id.rawValue) }
            if case .declarationID(let id) = declaration.meaning { try charge(id) }
        }
    }

    mutating func admit(_ shape: RouterHostShape, at scope: RouterScopePath) throws(RouterResourceLimitFailure) {
        let rootDepth = try RouterResourceBudget.addingResourceCount(
            scope.components.count, 1, maximum: limits.maximumGraphDepth, resource: "hostShape.depth"
        )
        if case .immersiveSpace(let id) = scope.domain { try charge(id) }
        for component in scope.components {
            if case .branch(let id) = component { try charge(id.rawValue) }
        }
        nodes = try RouterResourceBudget.addingResourceCount(
            nodes, 1, maximum: limits.maximumNodes, resource: "hostShape.nodes"
        )
        var work = [(shape: shape, depth: rootDepth)]
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            if case .custom(let id, _, _) = entry.shape { try charge(id) }
            let branches = entry.shape.branches
            nodes = try RouterResourceBudget.addingResourceCount(
                nodes, branches.count, maximum: limits.maximumNodes, resource: "hostShape.nodes"
            )
            guard !branches.isEmpty else { continue }
            let depth = try RouterResourceBudget.addingResourceCount(
                entry.depth, 1, maximum: limits.maximumGraphDepth, resource: "hostShape.depth"
            )
            for branch in branches {
                try charge(branch.id.rawValue)
                work.append((branch.shape, depth))
            }
        }
    }
}
