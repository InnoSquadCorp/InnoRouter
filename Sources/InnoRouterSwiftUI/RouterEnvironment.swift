import SwiftUI

import InnoRouterCore

typealias NavigationIntentHandler<R: Route> = @MainActor @Sendable (NavigationIntent<R>) -> Void
typealias ModalIntentHandler<R: Route> = @MainActor @Sendable (ModalIntent<R>) -> Void
typealias FlowIntentHandler<R: Route> = @MainActor @Sendable (FlowIntent<R>) -> Void

enum RouterTabAction<R: Route>: Sendable {
    case select(R)
    case setBadge(Int?, for: R)
    case clearAllBadges
}

typealias RouterTabActionHandler<R: Route> = @MainActor @Sendable (RouterTabAction<R>) -> Void

/// The route-typed capabilities published by an InnoRouter host.
///
/// This is intentionally internal. Consumers interact with the stable
/// ``RouterActions`` facade while hosts compose whichever low-level
/// navigation, modal, flow, and tab handlers they actually own.
struct RouterAuthority<R: Route>: Sendable {
    let navigation: NavigationIntentHandler<R>?
    let modal: ModalIntentHandler<R>?
    let flow: FlowIntentHandler<R>?
    let tab: RouterTabActionHandler<R>?

    init(
        navigation: NavigationIntentHandler<R>? = nil,
        modal: ModalIntentHandler<R>? = nil,
        flow: FlowIntentHandler<R>? = nil,
        tab: RouterTabActionHandler<R>? = nil
    ) {
        self.navigation = navigation
        self.modal = modal
        self.flow = flow
        self.tab = tab
    }
}

/// Main-actor-isolated erasure used only inside ``RouterEnvironment``.
///
/// Values enter through the generic subscript and are read back using the
/// same route metatype key. Isolating the erased payload keeps the environment
/// sendable without an unchecked conformance.
@MainActor
private final class ErasedRouterAuthority: Sendable {
    private let value: Any

    init<R: Route>(_ authority: RouterAuthority<R>) {
        self.value = authority
    }

    func authority<R: Route>(for routeType: R.Type) -> RouterAuthority<R>? {
        _ = routeType
        return value as? RouterAuthority<R>
    }
}

/// Value-semantic SwiftUI environment payload containing route-typed router
/// authorities. Value semantics are important here: a nested host receives a
/// snapshot of its parent's registrations and can override the matching route
/// type without mutating a sibling subtree.
struct RouterEnvironment: Sendable {
    private var authorities: [ObjectIdentifier: ErasedRouterAuthority] = [:]

    @MainActor
    subscript<R: Route>(routeType: R.Type) -> RouterAuthority<R>? {
        get {
            authorities[ObjectIdentifier(routeType)]?.authority(for: routeType)
        }
        set {
            let key = ObjectIdentifier(routeType)
            if let newValue {
                authorities[key] = ErasedRouterAuthority(newValue)
            } else {
                authorities.removeValue(forKey: key)
            }
        }
    }

    @MainActor
    mutating func register<R: Route>(
        _ authority: RouterAuthority<R>,
        for routeType: R.Type
    ) {
        // One host is one source of truth. Replacing the complete authority
        // prevents a nested stack-only host from accidentally combining its
        // navigation store with an outer host's modal, flow, or tab state.
        self[routeType] = authority
    }
}

extension EnvironmentValues {
    @Entry var routerEnvironment: RouterEnvironment?
}

extension View {
    /// Publishes host-owned router capabilities without exposing their
    /// dispatcher types as public API.
    @MainActor
    func routerAuthority<R: Route>(
        _ authority: RouterAuthority<R>,
        for routeType: R.Type
    ) -> some View {
        transformEnvironment(\.routerEnvironment) { environment in
            var resolved = environment ?? RouterEnvironment()
            resolved.register(authority, for: routeType)
            environment = resolved
        }
    }

    /// Convenience registration used by hosts that do not need to construct
    /// a ``RouterAuthority`` explicitly.
    @MainActor
    func routerAuthority<R: Route>(
        for routeType: R.Type,
        navigation: NavigationIntentHandler<R>? = nil,
        modal: ModalIntentHandler<R>? = nil,
        flow: FlowIntentHandler<R>? = nil,
        tab: RouterTabActionHandler<R>? = nil
    ) -> some View {
        routerAuthority(
            RouterAuthority(
                navigation: navigation,
                modal: modal,
                flow: flow,
                tab: tab
            ),
            for: routeType
        )
    }
}
