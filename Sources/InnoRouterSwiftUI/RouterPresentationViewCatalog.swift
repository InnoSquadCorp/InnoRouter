import SwiftUI

import InnoRouterCore

/// A frozen native renderer for one entry in the Store's presentation catalog.
/// The ID, shape, and root meanings must match the Core declaration exactly.
@MainActor
public struct RouterPresentationViewEntry<R: Route> {
    public let id: String
    public let shape: RouterHostShape
    public let rootDeclarations: [RouterHostRootDeclaration<R>]
    private let renderContent: ((RouterScope<R>) -> AnyView)?

    public init(_ id: String, rendering: RouterHostViewDescriptor<R>) where R: DestinationRoute {
        self.id = id
        self.shape = rendering.shape
        self.rootDeclarations = rendering.rootDeclarations
        self.renderContent = rendering.render
    }

    private init(stackID: String) {
        self.id = stackID
        self.shape = .stack
        self.rootDeclarations = []
        self.renderContent = nil
    }

    /// Explicit route-as-root stack semantics, including all canonical pushed
    /// destinations and recursively presented children in that stack.
    public static func stack(_ id: String) -> Self { Self(stackID: id) }

    /// The exact immutable Core metadata to install in the owning Store catalog.
    public var declaration: RouterHostCatalogEntry<R> {
        .init(id, shape: shape, rootDeclarations: rootDeclarations)
    }

    func render<Destination: View>(
        capture: RouterNavigationPresentationCapture<R>, destination: @escaping (R) -> Destination
    ) -> AnyView {
        if let renderContent { return renderContent(capture.child) }
        guard let presentation = capture.presentation else {
            return AnyView(RouterHostRecoveryView(failure: .init(code: .stale, scope: capture.child.path)))
        }
        return AnyView(RouterStoreStackSurface(
            scope: capture.child, destination: destination,
            root: { destination(presentation.route) }
        ).routerAuthority(capture.child, for: R.self))
    }
}

/// Immutable SwiftUI counterparts to the owning Store's frozen presentation
/// declarations. There is no second route resolver: selection uses only the
/// Store descriptor's admitted lookup, including for nested presentations.
@MainActor
public struct RouterPresentationViewCatalog<R: Route> {
    public let entries: [RouterPresentationViewEntry<R>]

    public init(entries: [RouterPresentationViewEntry<R>]) { self.entries = entries }

    public static var stack: Self { Self(entries: [.stack("stack")]) }
    public static var none: Self { Self(entries: []) }

    /// Checks all entries, including inactive ones. No Store state is mutated.
    public func validate(for store: RouterStore<R>) throws(RouterHostValidationFailure) {
        guard let descriptor = store.hostDescriptor else { throw .init(code: .required) }
        try validate(against: descriptor.presentations.entries, resourceBudget: store.resourceBudget)
    }

    func resolve(
        _ capture: RouterNavigationPresentationCapture<R>
    ) throws(RouterHostValidationFailure) -> RouterPresentationViewEntry<R> {
        guard capture.isCurrent, let store = capture.owner.store else {
            throw .init(code: .stale, scope: capture.child.path)
        }
        guard let descriptor = store.hostDescriptor else {
            throw .init(code: .required, scope: capture.child.path)
        }
        try validate(against: descriptor.presentations.entries, resourceBudget: store.resourceBudget)
        // The accessor retains ID and shape from one admitted traversal. Calling
        // the application resolver again here could choose a different entry.
        let declaration = try descriptor.presentationDeclaration(
            at: capture.child.path, in: store.state, resourceBudget: store.resourceBudget
        )
        guard let entry = entries.first(where: { $0.id == declaration.id }),
              entry.shape == declaration.shape,
              Self.rootsMatch(entry.rootDeclarations, declaration.rootDeclarations) else {
            throw .init(code: .rendererMismatch, scope: capture.child.path)
        }
        return entry
    }

    /// Declarations are mappings, not an ordering contract. Both arrays have
    /// already passed admission and uniqueness checks before this comparison.
    private static func rootsMatch(
        _ lhs: [RouterHostRootDeclaration<R>], _ rhs: [RouterHostRootDeclaration<R>]
    ) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { declaration in
            rhs.first(where: { $0.path == declaration.path })?.meaning.matches(declaration.meaning) == true
        }
    }

    private func validate(
        against declared: [RouterHostCatalogEntry<R>], resourceBudget: RouterResourceBudget
    ) throws(RouterHostValidationFailure) {
        // Validate fixed native declarations before equality, lookup, or view
        // closure evaluation. The empty input is deliberate: it cannot infer
        // a renderer or invoke an application route resolver.
        let declaration = RouterHostDescriptor<R>(
            root: .stack,
            presentations: .init(entries: entries.map(\.declaration), declaration: { _ in nil })
        )
        try declaration.validate(.rootStack, resourceBudget: resourceBudget)
        guard entries.count == declared.count else { throw .init(code: .rendererMismatch) }
        for entry in entries {
            guard let expected = declared.first(where: { $0.id == entry.id }),
                  expected.shape == entry.shape,
                  Self.rootsMatch(expected.rootDeclarations, entry.rootDeclarations) else {
                throw .init(code: .rendererMismatch)
            }
        }
    }
}

/// Type-erased value inheritance for native views. Captures contain only weak
/// same-Store scopes; this registry never acquires navigation ownership.
struct RouterPresentationRenderEnvironment: Sendable {
    private var values: [ObjectIdentifier: RouterPresentationRenderBox] = [:]

    @MainActor
    subscript<R: Route>(route: R.Type) -> RouterPresentationRenderValues<R>? {
        get { values[ObjectIdentifier(route)]?.value as? RouterPresentationRenderValues<R> }
        set { values[ObjectIdentifier(route)] = newValue.map { RouterPresentationRenderBox($0) } }
    }
}

@MainActor
private final class RouterPresentationRenderBox: Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

@MainActor
struct RouterPresentationRenderValues<R: Route> {
    var catalog: RouterPresentationViewCatalog<R>
    var context: RouterNavigationPresentationRenderContext<R>?
}

extension EnvironmentValues {
    @Entry var routerPresentationRendering = RouterPresentationRenderEnvironment()
}

extension View {
    @MainActor
    func routerPresentationCatalog<R: Route>(_ catalog: RouterPresentationViewCatalog<R>) -> some View {
        transformEnvironment(\.routerPresentationRendering) { environment in
            let context = environment[R.self]?.context
            environment[R.self] = .init(catalog: catalog, context: context)
        }
    }

    @MainActor
    func routerNavigationPresentation<R: Route>(
        _ capture: RouterNavigationPresentationCapture<R>, catalog: RouterPresentationViewCatalog<R>
    ) -> some View {
        self.routerAuthority(capture.child, for: R.self)
            .transformEnvironment(\.routerPresentationRendering) { environment in
                environment[R.self] = .init(catalog: catalog, context: .init(capture: capture))
            }
    }
}

@MainActor
struct RouterHostAuthorityModifier<R: Route>: ViewModifier {
    @Environment(\.routerPresentationRendering) private var rendering
    let scope: RouterScope<R>

    func body(content: Content) -> some View {
        let values = rendering[R.self]
        let context = values?.context
        return content
            .transformEnvironment(\.routerEnvironment) { environment in
                let inherited = environment ?? RouterEnvironment()
                if let rebased = context?.rebase(inherited, onto: scope) {
                    environment = rebased
                } else {
                    var resolved = inherited
                    resolved.register(RouterAuthority(scope: scope), for: R.self)
                    environment = resolved
                }
            }
            .transformEnvironment(\.routerPresentationRendering) { environment in
                guard var values else { return }
                values.context = context?.scoped(to: scope)
                environment[R.self] = values
            }
    }
}
