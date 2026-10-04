import SwiftUI

import InnoRouterCore

/// Reads route actions from the nearest route-typed InnoRouter authority.
@MainActor
@propertyWrapper
public struct EnvironmentRouter<R: Route>: DynamicProperty {
    @Environment(\.routerEnvironment) private var routerEnvironment
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var environmentMissingPolicy
    private let routeType: R.Type

    public init(_ routeType: R.Type) {
        self.routeType = routeType
    }

    public var wrappedValue: RouterActions<R> {
        RouterActions(
            routeType: routeType,
            environmentMissingPolicy: environmentMissingPolicy,
            environment: routerEnvironment
        )
    }
}
