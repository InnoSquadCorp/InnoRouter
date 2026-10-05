// InnoRouterCore - frozen host declarations for complete navigation values

/// One stable declaration and its route-independent renderer shape.
/// IDs are semantic application identifiers, not instance IDs or route payloads.
public struct RouterHostCatalogEntry: Sendable {
    public let id: String
    public let shape: RouterHostShape

    public init(_ id: String, shape: RouterHostShape) {
        self.id = id
        self.shape = shape
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
    public let entries: [RouterHostCatalogEntry]
    package let declaration: @Sendable (R) -> String?

    public init(
        entries: [RouterHostCatalogEntry],
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
    public let presentations: RouterHostCatalog<R>
    public let windows: RouterHostCatalog<R>
    public let immersiveSpaces: RouterHostCatalog<R>

    public init(
        root: RouterHostShape,
        presentations: RouterHostCatalog<R> = .stack,
        windows: RouterHostCatalog<R> = .none,
        immersiveSpaces: RouterHostCatalog<R> = .none
    ) {
        self.root = root
        self.presentations = presentations
        self.windows = windows
        self.immersiveSpaces = immersiveSpaces
    }

    public func validate(
        _ input: RouterStateDraft<R>, resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        _ = try validatedShapes(in: input, resourceBudget: resourceBudget)
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
        let shapes = try validatedShapes(in: input, resourceBudget: resourceBudget)
        guard let shape = shapes[scope] else {
            throw RouterHostValidationFailure(code: .missingScope, scope: scope, detail: .nodeUnavailable)
        }
        return shape
    }

    /// Verifies that a native renderer carries the same already-declared shape.
    /// This does not register or mutate a descriptor and does not infer shape
    /// from a matching current candidate. Orphan policy is part of the contract.
    public func validateRenderer(
        _ renderer: RouterHostShape, at scope: RouterScopePath, in state: RouterState<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        try validateRenderer(renderer, at: scope, in: RouterStateDraft(state), resourceBudget: resourceBudget)
    }

    public func validateRenderer(
        _ renderer: RouterHostShape, at scope: RouterScopePath, in input: RouterStateDraft<R>,
        resourceBudget: RouterResourceBudget = .provisional
    ) throws(RouterHostValidationFailure) {
        do {
            try renderer.admitDeclaration(at: scope, limits: resourceBudget.snapshot)
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try renderer.validateScope(scope)
        try renderer.validateDeclaration(at: scope)
        let declared = try shape(at: scope, in: input, resourceBudget: resourceBudget)
        guard renderer == declared else {
            throw RouterHostValidationFailure(code: .rendererMismatch, scope: scope, detail: .rendererDeclaration)
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

    func validatedShapes(
        in input: RouterStateDraft<R>, resourceBudget: RouterResourceBudget
    ) throws(RouterHostValidationFailure) -> [RouterScopePath: RouterHostShape] {
        var admission = RouterHostDeclarationAdmission(limits: resourceBudget.snapshot)
        do {
            try resourceBudget.validate(root: input.root, windows: input.windows, immersiveSpace: input.immersiveSpace)
            try admission.admit(root, at: .root)
            // Preflight every catalog, including entries unused by this input,
            // as one descriptor before any declaration identifier is hashed.
            for catalog in [presentations, windows, immersiveSpaces] {
                for entry in catalog.entries {
                    try admission.charge(entry.id)
                    try admission.admit(entry.shape, at: .root)
                }
            }
        } catch {
            throw RouterHostValidationFailure(code: .resourceLimit, scope: .root, detail: .resource(error))
        }
        try root.validateDeclaration(at: .root)
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
        for window in state.windows {
            let scope = RouterScopePath.window(window.id)
            let resolved = try resolve(window.route, catalog: windows, shapes: windowShapes, at: scope, admission: &admission)
            work.append((window.node, resolved.shape, scope, true))
        }
        if let immersive = state.immersiveSpace {
            let scope = RouterScopePath.immersiveSpace(immersive.id)
            let resolved = try resolve(immersive.route, catalog: immersiveSpaces, shapes: immersiveShapes, at: scope, admission: &admission)
            guard resolved.id == immersive.id else {
                throw RouterHostValidationFailure(code: .sceneIdentifierMismatch, scope: scope, detail: .sceneIdentifier)
            }
            work.append((immersive.node, resolved.shape, scope, true))
        }
        var renderedShapes: [RouterScopePath: RouterHostShape] = [:]
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            if let shape = entry.shape {
                try shape.match(entry.node, at: entry.scope)
                if entry.rendered { renderedShapes[entry.scope] = shape }
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
                }
            case .container(let container):
                let declared = Dictionary(uniqueKeysWithValues: (entry.shape?.branches ?? []).map { ($0.id, $0.shape) })
                for branch in container.branches {
                    let shape = declared[branch.id]
                    work.append((branch.node, shape, entry.scope.appending(branch.id), entry.rendered && shape != nil))
                }
            }
        }
        return renderedShapes
    }

    func validateCatalog(_ catalog: RouterHostCatalog<R>) throws(RouterHostValidationFailure) -> [String: RouterHostShape] {
        var shapes: [String: RouterHostShape] = [:]
        for entry in catalog.entries {
            guard !entry.id.isEmpty else {
                throw RouterHostValidationFailure(code: .invalidDeclaration, scope: .root, detail: .emptyIdentifier)
            }
            guard shapes[entry.id] == nil else {
                throw RouterHostValidationFailure(code: .duplicateDeclaration, scope: .root, detail: .catalogDeclaration)
            }
            try entry.shape.validateDeclaration(at: .root)
            shapes[entry.id] = entry.shape
        }
        return shapes
    }

    func resolve(
        _ route: R, catalog: RouterHostCatalog<R>, shapes: [String: RouterHostShape],
        at scope: RouterScopePath, admission: inout RouterHostDeclarationAdmission
    ) throws(RouterHostValidationFailure) -> (id: String, shape: RouterHostShape) {
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
        guard let shape = shapes[id] else {
            throw RouterHostValidationFailure(code: .unknownDeclaration, scope: scope, detail: .catalogDeclaration)
        }
        return (id, shape)
    }
}
