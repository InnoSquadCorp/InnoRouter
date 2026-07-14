import Foundation
import SwiftUI

import InnoRouterCore

typealias NavigationIntentHandler<R: Route> = @MainActor @Sendable (NavigationIntent<R>) -> Void

@MainActor
final class NavigationEnvironmentStorage {
    private var intentDispatchers: [ObjectIdentifier: Any] = [:]

    init() {}

    subscript<R: Route>(routeType: R.Type) -> NavigationIntentHandler<R>? {
        get {
            let registration = intentDispatchers[ObjectIdentifier(routeType)]
                as? DispatcherRegistration<NavigationIntentHandler<R>>
            return registration?.dispatcher
        }
        set {
            setIntentDispatcher(
                newValue,
                ownerID: newValue.map { _ in ObjectIdentifier(self) },
                routeType: routeType
            )
        }
    }

    func setIntentDispatcher<R: Route>(
        _ dispatcher: NavigationIntentHandler<R>?,
        ownerID: ObjectIdentifier?,
        routeType: R.Type
    ) {
        let key = ObjectIdentifier(routeType)
        let existing = intentDispatchers[key]
            as? DispatcherRegistration<NavigationIntentHandler<R>>
        let replacement = dispatcher.map {
            DispatcherRegistration(
                dispatcher: $0,
                ownerID: ownerID ?? ObjectIdentifier(self)
            )
        }
        reportDuplicateDispatcherIfNeeded(
            existing: existing,
            replacement: replacement,
            keyDescription: "NavigationIntent handler for \(String(describing: routeType))"
        )
        if let replacement {
            intentDispatchers[key] = replacement
        } else {
            intentDispatchers.removeValue(forKey: key)
        }
    }
}

extension EnvironmentValues {
    @Entry var navigationEnvironmentStorage: NavigationEnvironmentStorage?
}

extension View {
    @MainActor
    func navigationIntentDispatcher<R: Route>(
        _ dispatcher: @escaping NavigationIntentHandler<R>,
        owner: AnyObject
    ) -> some View {
        transformEnvironment(\.navigationEnvironmentStorage) { storage in
            guard let storage else {
                assertionFailure(
                    "NavigationEnvironmentStorage is missing. Attach this view inside NavigationHost or CoordinatorHost."
                )
                return
            }
            storage.setIntentDispatcher(
                dispatcher,
                ownerID: ObjectIdentifier(owner),
                routeType: R.self
            )
        }
    }
}

/// Reads the low-level `NavigationIntent` dispatcher for a route type.
///
/// Prefer ``EnvironmentRouter`` for ordinary push and pop actions. Use this
/// wrapper when a feature needs to construct `NavigationIntent` directly.
/// Missing or mismatched hosts follow ``EnvironmentMissingPolicy``.
///
/// ```swift
/// @EnvironmentNavigationIntent(AppRoute.self) private var dispatch
///
/// dispatch(.go(.detail(id: "42")))
/// ```
@MainActor
@propertyWrapper
public struct EnvironmentNavigationIntent<R: Route>: DynamicProperty {
    @Environment(\.navigationEnvironmentStorage) private var navigationEnvironmentStorage
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var environmentMissingPolicy
    private let routeType: R.Type

    public init(_ routeType: R.Type) {
        self.routeType = routeType
    }

    public var wrappedValue: @MainActor @Sendable (NavigationIntent<R>) -> Void {
        if let dispatcher = navigationEnvironmentStorage?[R.self] {
            return dispatcher
        }
        if navigationEnvironmentStorage == nil {
            handleMissingEnvironment(policy: environmentMissingPolicy) {
                "NavigationEnvironmentStorage is missing for \(String(describing: routeType)). " +
                "Attach this view inside NavigationHost or CoordinatorHost."
            }
        } else {
            handleMissingEnvironment(policy: environmentMissingPolicy) {
                "NavigationIntent handler is missing for \(String(describing: routeType)). " +
                "Ensure the matching NavigationHost or CoordinatorHost is in the environment hierarchy."
            }
        }
        return { _ in /* no-op placeholder */ }
    }
}
