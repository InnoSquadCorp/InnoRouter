// InnoRouterCore - frozen host declarations for complete navigation values

/// One stable declaration and its route-independent renderer shape.
/// IDs are semantic application identifiers, not instance IDs or route payloads.
public struct RouterHostCatalogEntry<R: Route>: Sendable {
    public let id: String
    public let shape: RouterHostShape
    public let rootDeclarations: [RouterHostRootDeclaration<R>]

    public init(
        _ id: String, shape: RouterHostShape,
        rootDeclarations: [RouterHostRootDeclaration<R>] = []
    ) {
        self.id = id
        self.shape = shape
        self.rootDeclarations = rootDeclarations
    }
}

/// A frozen set of possible child hosts, built independently of candidate state.
///
/// The resolver selects a declaration ID from a route; it never returns a shape
/// and cannot add a declaration. It must be pure and stable for this catalog's
/// lifetime. Capture immutable configuration. To change the mapping, replace
/// the owning Store's complete descriptor through its explicit replacement API.
/// Arbitrary synchronous application callback work cannot be preempted by the
/// library. Resource/structure admission completes before any resolver runs.
public struct RouterHostCatalog<R: Route>: Sendable {
    public let entries: [RouterHostCatalogEntry<R>]
    package let declaration: @Sendable (R) -> String?

    public init(
        entries: [RouterHostCatalogEntry<R>],
        declaration: @escaping @Sendable (R) -> String?
    ) {
        self.entries = entries
        self.declaration = declaration
    }

    /// Explicitly declares that every route uses a stack child host.
    /// Suitable for presentations and regular windows. Immersive catalogs use
    /// explicit entries whose IDs also match their stored scene identifiers.
    public static var stack: Self {
        Self(entries: [.init("stack", shape: .stack)], declaration: { _ in "stack" })
    }

    /// Rejects every route in this surface's navigation catalog.
    public static var none: Self { Self(entries: [], declaration: { _ in nil }) }
}

/// The immutable renderer contract owned by one Store boundary.
///
/// Describes application, presentation, regular-window and immersive roots with
/// no candidate-derived fallback. Every candidate is admitted as a whole before
/// matching. Rejected validation never edits, drops or reconciles any branch.
/// A preserved dormant branch stays structurally/resource validated; any nested
/// presentations still require declared catalog shapes. A dormant branch is
/// never returned by ``shape(at:in:resourceBudget:)`` as a renderable scope.
public struct RouterHostDescriptor<R: Route>: Sendable {
    public let root: RouterHostShape
    public let rootDeclarations: [RouterHostRootDeclaration<R>]
    public let presentations: RouterHostCatalog<R>
    public let windows: RouterHostCatalog<R>
    public let immersiveSpaces: RouterHostCatalog<R>

    public init(
        root: RouterHostShape,
        rootDeclarations: [RouterHostRootDeclaration<R>] = [],
        presentations: RouterHostCatalog<R> = .stack,
        windows: RouterHostCatalog<R> = .none,
        immersiveSpaces: RouterHostCatalog<R> = .none
    ) {
        self.root = root
        self.rootDeclarations = rootDeclarations
        self.presentations = presentations
        self.windows = windows
        self.immersiveSpaces = immersiveSpaces
    }

    public func validate(
        _ input: RouterStateDraft<R>, resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        _ = try validatedDeclarations(in: input, resourceBudget: resourceBudget)
    }

    public func validate(
        _ state: RouterState<R>, resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        try validate(RouterStateDraft(state), resourceBudget: resourceBudget)
    }

    /// Returns the explicit declaration at a rendered scope, after checking the
    /// whole input. State determines instance addresses, never renderer shapes.
    public func shape(
        at scope: RouterScopePath, in state: RouterState<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) -> RouterHostShape {
        try shape(at: scope, in: RouterStateDraft(state), resourceBudget: resourceBudget)
    }

    public func shape(
        at scope: RouterScopePath, in input: RouterStateDraft<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) -> RouterHostShape {
        try admitScope(scope, resourceBudget: resourceBudget)
        let declarations = try validatedDeclarations(in: input, resourceBudget: resourceBudget)
        guard let shape = declarations.shapes[scope] else {
            throw RouterHostValidationFailure(code: .missingScope, scope: scope, detail: .nodeUnavailable)
        }
        return shape
    }

    /// Resolves one rendered presentation from the same admitted traversal that
    /// validates its shape. Do not invoke the application resolver a second time
    /// to choose a native renderer after validating a candidate.
    package func presentationDeclaration(
        at scope: RouterScopePath, in state: RouterState<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) -> RouterHostCatalogEntry<R> {
        try admitScope(scope, resourceBudget: resourceBudget)
        let declarations = try validatedDeclarations(in: RouterStateDraft(state), resourceBudget: resourceBudget)
        guard let declaration = declarations.presentations[scope] else {
            throw RouterHostValidationFailure(code: .missingScope, scope: scope, detail: .nodeUnavailable)
        }
        return declaration
    }

    /// Verifies that a native renderer carries the same declared shape and root
    /// meanings. Omitting root declarations means an empty mapping, never a
    /// request to skip semantic validation. Child scopes compare only their
    /// declared branch subtree, with root paths relative to that child.
    /// This does not register or mutate a descriptor and does not infer shape
    /// from a matching current candidate. Orphan policy is part of the contract.
    public func validateRenderer(
        _ renderer: RouterHostShape, rootDeclarations: [RouterHostRootDeclaration<R>] = [],
        at scope: RouterScopePath, in state: RouterState<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        try validateRenderer(renderer, rootDeclarations: rootDeclarations, at: scope, in: RouterStateDraft(state), resourceBudget: resourceBudget)
    }

    public func validateRenderer(
        _ renderer: RouterHostShape, rootDeclarations: [RouterHostRootDeclaration<R>] = [],
        at scope: RouterScopePath, in input: RouterStateDraft<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        do {
            var admission = RouterHostDeclarationAdmission(limits: resourceBudget.snapshot)
            try admission.admit(renderer, at: scope)
            try admission.admitRootDeclarations(rootDeclarations, at: scope)
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try renderer.validateScope(scope)
        try renderer.validateDeclaration(at: scope)
        try validateRootDeclarations(rootDeclarations, shape: renderer)
        let declarations = try validatedDeclarations(in: input, resourceBudget: resourceBudget)
        guard let declared = declarations.shapes[scope] else {
            throw RouterHostValidationFailure(code: .missingScope, scope: scope, detail: .nodeUnavailable)
        }
        guard renderer == declared else {
            throw RouterHostValidationFailure(code: .rendererMismatch, scope: scope, detail: .rendererDeclaration)
        }
        // All supplied paths, shapes, semantic IDs, and the entire candidate are
        // admitted before route equality. No Route hash/description is needed.
        let expected = declarations.relativeRoots(at: scope)
        guard expected.count == rootDeclarations.count else {
            throw RouterHostValidationFailure(code: .rendererMismatch, scope: scope, detail: .rendererDeclaration)
        }
        for declaration in rootDeclarations {
            guard let meaning = expected[declaration.path], meaning.matches(declaration.meaning) else {
                throw RouterHostValidationFailure(code: .rendererMismatch, scope: scope, detail: .rendererDeclaration)
            }
        }
    }
}

private extension RouterHostDescriptor {
    func admitScope(
        _ scope: RouterScopePath, resourceBudget: RouterResourceBudget
    ) throws(RouterHostValidationFailure) {
        do {
            try RouterHostShape.stack.admitDeclaration(at: scope, limits: resourceBudget.snapshot)
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try RouterHostShape.stack.validateScope(scope)
    }

    func validatedDeclarations(
        in input: RouterStateDraft<R>, resourceBudget: RouterResourceBudget
    ) throws(RouterHostValidationFailure) -> RouterValidatedHostDeclarations<R> {
        var admission = RouterHostDeclarationAdmission(limits: resourceBudget.snapshot)
        do {
            try resourceBudget.validate(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
            try admission.admit(root, at: .root)
            try admission.admitRootDeclarations(rootDeclarations, at: .root)
            // Preflight every catalog, including entries unused by this input,
            // as one descriptor before any declaration identifier is hashed.
            for catalog in [presentations, windows, immersiveSpaces] {
                for entry in catalog.entries {
                    try admission.charge(entry.id)
                    try admission.admit(entry.shape, at: .root)
                    try admission.admitRootDeclarations(entry.rootDeclarations, at: .root)
                }
            }
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try root.validateDeclaration(at: .root)
        try validateRootDeclarations(rootDeclarations, shape: root)
        let presentationShapes = try validateCatalog(presentations)
        let windowShapes = try validateCatalog(windows)
        let immersiveShapes = try validateCatalog(immersiveSpaces)
        let state: RouterState<R>
        do {
            state = try RouterState(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
        } catch {
            throw RouterHostValidationFailure(code: .invalidState, scope: .root, detail: .stateStructure)
        }

        // Instance paths are derived only from the admitted complete state.
        // Shapes always come from the root declaration or the frozen catalog.
        var work: [(node: RouterNode<R>, shape: RouterHostShape?, scope: RouterScopePath, rendered: Bool)] = [
            (state.root, root, .root, true),
        ]
        var result = RouterValidatedHostDeclarations<R>()
        var rootsToRecord: [(scope: RouterScopePath, declarations: [RouterHostRootDeclaration<R>])] = [
            (.root, rootDeclarations),
        ]
        for window in state.windows {
            let scope = RouterScopePath.window(window.id)
            let resolved = try resolve(window.route, catalog: windows, shapes: windowShapes, at: scope, admission: &admission)
            work.append((window.node, resolved.shape, scope, true))
            rootsToRecord.append((scope, resolved.rootDeclarations))
        }
        if let immersive = state.immersiveSpace {
            let scope = RouterScopePath.immersiveSpace(immersive.id)
            let resolved = try resolve(immersive.route, catalog: immersiveSpaces, shapes: immersiveShapes, at: scope, admission: &admission)
            guard resolved.id == immersive.id else {
                throw RouterHostValidationFailure(code: .sceneIdentifierMismatch, scope: scope, detail: .sceneIdentifier)
            }
            work.append((immersive.node, resolved.shape, scope, true))
            rootsToRecord.append((scope, resolved.rootDeclarations))
        }
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            if let shape = entry.shape {
                try shape.match(entry.node, at: entry.scope)
                if entry.rendered { result.shapes[entry.scope] = shape }
            }
            switch entry.node {
            case .stack(let stack):
                if let presentation = stack.presentation {
                    let scope = entry.scope.appendingPresentation(presentation.id)
                    let resolved = try resolve(
                        presentation.route, catalog: presentations, shapes: presentationShapes,
                        at: scope, admission: &admission
                    )
                    work.append((presentation.node, resolved.shape, scope, entry.rendered))
                    if entry.rendered {
                        result.presentations[scope] = resolved
                        rootsToRecord.append((scope, resolved.rootDeclarations))
                    }
                }
            case .container(let container):
                let declared = Dictionary(uniqueKeysWithValues: (entry.shape?.branches ?? []).map { ($0.id, $0.shape) })
                for branch in container.branches {
                    let shape = declared[branch.id]
                    work.append((branch.node, shape, entry.scope.appending(branch.id), entry.rendered && shape != nil))
                }
            }
        }
        // Every target below now names a matched, resource-admitted state node.
        // Delay anchoring relative root paths until all descendants match; an
        // incompatible catalog must not amplify instance count by declaration
        // size or construct paths deeper than the admitted candidate.
        for record in rootsToRecord {
            result.recordRoots(record.declarations, at: record.scope)
        }
        return result
    }

    func validateCatalog(_ catalog: RouterHostCatalog<R>) throws(RouterHostValidationFailure) -> [String: RouterHostCatalogEntry<R>] {
        var shapes: [String: RouterHostCatalogEntry<R>] = [:]
        for entry in catalog.entries {
            guard !entry.id.isEmpty else {
                throw RouterHostValidationFailure(code: .invalidDeclaration, scope: .root, detail: .emptyIdentifier)
            }
            guard shapes[entry.id] == nil else {
                throw RouterHostValidationFailure(code: .duplicateDeclaration, scope: .root, detail: .catalogDeclaration)
            }
            try entry.shape.validateDeclaration(at: .root)
            try validateRootDeclarations(entry.rootDeclarations, shape: entry.shape)
            shapes[entry.id] = entry
        }
        return shapes
    }

    func resolve(
        _ route: R, catalog: RouterHostCatalog<R>, shapes: [String: RouterHostCatalogEntry<R>],
        at scope: RouterScopePath, admission: inout RouterHostDeclarationAdmission
    ) throws(RouterHostValidationFailure) -> RouterHostCatalogEntry<R> {
        guard let id = catalog.declaration(route) else {
            throw RouterHostValidationFailure(code: .unknownDeclaration, scope: scope, detail: .catalogDeclaration)
        }
        do {
            // Bound application resolver output before equality/hashing. Repeated
            // results count again; returning a giant or unknown key never leaks it.
            try admission.charge(id)
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        guard let entry = shapes[id] else {
            throw RouterHostValidationFailure(code: .unknownDeclaration, scope: scope, detail: .catalogDeclaration)
        }
        return entry
    }
}

private extension RouterHostDescriptor {
    /// Resource admission and shape validation must precede this operation.
    func validateRootDeclarations(
        _ declarations: [RouterHostRootDeclaration<R>], shape: RouterHostShape
    ) throws(RouterHostValidationFailure) {
        var paths: Set<[RouterScopeID]> = []
        for declaration in declarations {
            guard paths.insert(declaration.path).inserted else {
                throw RouterHostValidationFailure(code: .duplicateDeclaration, scope: .root, detail: .rendererDeclaration)
            }
            if case .declarationID(let id) = declaration.meaning, id.isEmpty {
                throw RouterHostValidationFailure(code: .invalidDeclaration, scope: .root, detail: .emptyIdentifier)
            }
            var target = shape
            for id in declaration.path {
                guard !id.rawValue.isEmpty else {
                    throw RouterHostValidationFailure(code: .invalidDeclaration, scope: .root, detail: .emptyIdentifier)
                }
                guard let child = target.branches.first(where: { $0.id == id }) else {
                    throw RouterHostValidationFailure(code: .invalidDeclaration, scope: .root, detail: .declaredBranchUnavailable)
                }
                target = child.shape
            }
        }
    }
}

private struct RouterValidatedHostDeclarations<R: Route> {
    var shapes: [RouterScopePath: RouterHostShape] = [:]
    var presentations: [RouterScopePath: RouterHostCatalogEntry<R>] = [:]
    var roots: [RouterScopePath: RouterHostRootMeaning<R>] = [:]

    mutating func recordRoots(_ declarations: [RouterHostRootDeclaration<R>], at scope: RouterScopePath) {
        for declaration in declarations {
            let path = RouterScopePath(
                scope.components + declaration.path.map { .branch($0) }, domain: scope.domain
            )
            roots[path] = declaration.meaning
        }
    }

    func relativeRoots(at scope: RouterScopePath) -> [[RouterScopeID]: RouterHostRootMeaning<R>] {
        var result: [[RouterScopeID]: RouterHostRootMeaning<R>] = [:]
        for (path, meaning) in roots {
            guard path.domain == scope.domain, path.components.starts(with: scope.components) else { continue }
            let suffix = path.components.dropFirst(scope.components.count)
            let branchPath = suffix.compactMap { component -> RouterScopeID? in
                if case .branch(let id) = component { return id }
                return nil
            }
            // A renderer's declaration owns branch descendants. Dynamic child
            // presentations have their own independently validated entry.
            guard branchPath.count == suffix.count else { continue }
            result[branchPath] = meaning
        }
        return result
    }
}
