import InnoRouterCore
import SwiftUI

/// View-layer intent dispatched to ``NavigationStore/send(_:)``.
///
/// Conformance to `Sendable` is **unconditional** because every ``Route`` is
/// required to be `Sendable`. Callers can therefore freely move
/// `NavigationIntent` values across actor boundaries without
/// additional `where R: Sendable` constraints.
public enum NavigationIntent<R: Route>: Sendable, Equatable {
    case go(R)
    /// Projects an empty array to no command, one route to `.push`, and
    /// multiple routes to one atomic `.pushAll` command.
    case goMany([R])
    case back
    /// Normalizes a positive count equal to the current stack depth to
    /// `.popToRoot`; other counts project to `.popCount`.
    case backBy(Int)
    case backTo(R)
    case backToRoot
    /// Replaces the entire navigation stack with the supplied routes.
    case replaceStack([R])
    /// Pops back to the matching route when the current stack already contains
    /// an equal route; otherwise pushes the supplied route.
    case backOrPush(R)
    /// Pushes the route only when the current stack does not already contain
    /// an equal route anywhere in the stack.
    case pushUniqueRoot(R)
}

/// View-layer coordinator that owns a navigation store, dispatches
/// intents, and renders destinations.
///
/// > Lifecycle: A `Coordinator` may opt into the cross-cutting
/// > ``LifecycleAware`` capability to expose teardown hooks via the
/// > shared ``LifecycleSignals`` bag. Adopting `LifecycleAware`
/// > lets host code fire `lifecycleSignals.fireTeardown()` when the
/// > coordinator is being released so transient state can be
/// > cancelled. `ChildCoordinator` inherits `LifecycleAware`
/// > unconditionally because the child result-wait helper drives
/// > `onParentCancel` through it.
@MainActor
public protocol Coordinator: AnyObject, Observable {
    associatedtype RouteType: Route
    associatedtype Destination: View

    var store: NavigationStore<RouteType> { get }

    func handle(_ intent: NavigationIntent<RouteType>)
    @ViewBuilder
    func destination(for route: RouteType) -> Destination
}

public extension Coordinator {
    func handle(_ intent: NavigationIntent<RouteType>) {
        store.send(intent)
    }

    func send(_ intent: NavigationIntent<RouteType>) {
        handle(intent)
    }
}

extension Coordinator {
    var navigationIntentDispatcher: NavigationIntentHandler<RouteType> {
        { [weak self] intent in
            self?.handle(intent)
        }
    }
}

private struct CoordinatorStackHostContent<C: Coordinator, Root: View>: View {
    @Bindable private var coordinator: C
    private let root: () -> Root

    init(
        coordinator: C,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.coordinator = coordinator
        self.root = root
    }

    var body: some View {
        NavigationStack(path: coordinator.store.pathBinding) {
            root()
                .navigationDestination(for: C.RouteType.self) { route in
                    coordinator.destination(for: route)
                }
        }
    }
}

/// Hosts a stack-based coordinator surface and publishes its navigation
/// authority through ``EnvironmentRouter``.
public struct CoordinatorHost<C: Coordinator, Root: View>: View {
    @Bindable private var coordinator: C
    private let root: () -> Root

    /// Creates a coordinator host with the supplied coordinator and root builder.
    public init(
        coordinator: C,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.coordinator = coordinator
        self.root = root
    }

    public var body: some View {
        let navigationDispatcher = coordinator.navigationIntentDispatcher

        CoordinatorStackHostContent(coordinator: coordinator, root: root)
            .routerAuthority(
                for: C.RouteType.self,
                navigation: navigationDispatcher
            )
    }
}

// MARK: - Platform: NavigationSplitView is unavailable on watchOS.
// `CoordinatorSplitHost` is therefore declared only on non-watchOS platforms.
// watchOS consumers should fall back to `CoordinatorHost`.
#if !os(watchOS)
/// Hosts a split-view coordinator surface whose detail column is driven by the coordinator's store.
///
/// - Important: This host is **not available on watchOS** because SwiftUI's
///   `NavigationSplitView` is unavailable there. Use ``CoordinatorHost``
///   inside a `#if !os(watchOS)` fallback on watchOS targets.
public struct CoordinatorSplitHost<C: Coordinator, Sidebar: View, Root: View>: View {
    @Bindable private var coordinator: C
    private let sidebar: () -> Sidebar
    private let root: () -> Root

    /// Creates a split coordinator host with separate sidebar and root builders.
    public init(
        coordinator: C,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.coordinator = coordinator
        self.sidebar = sidebar
        self.root = root
    }

    public var body: some View {
        let navigationDispatcher = coordinator.navigationIntentDispatcher

        NavigationSplitView {
            sidebar()
        } detail: {
            CoordinatorStackHostContent(coordinator: coordinator, root: root)
        }
        .routerAuthority(
            for: C.RouteType.self,
            navigation: navigationDispatcher
        )
    }
}
#endif
