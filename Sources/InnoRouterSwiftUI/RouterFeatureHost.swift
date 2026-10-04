import SwiftUI

import InnoRouterCore

/// Publishes a macro-generated feature mapping to descendants without
/// creating another navigation store or native host.
@MainActor
public struct RouterFeatureHost<Parent: Route, Child: Route, Content: View>: View {
    @Environment(\.routerEnvironment) private var routerEnvironment
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var missingPolicy

    private let mapping: RouterFeatureMapping<Parent, Child>
    private let content: () -> Content

    public init(
        _ mapping: RouterFeatureMapping<Parent, Child>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.mapping = mapping
        self.content = content
    }

    @ViewBuilder
    public var body: some View {
        if let parent = routerEnvironment?[Parent.self] {
            let feature = RouterFeatureScope(parent: parent.base, mapping: mapping)
            content()
                .transformEnvironment(\.routerEnvironment) { environment in
                    var resolved = environment ?? RouterEnvironment()
                    resolved.register(RouterAuthority(base: feature), for: Child.self)
                    environment = resolved
                }
        } else {
            missingParentContent()
        }
    }

    private func missingParentContent() -> Content {
        handleMissingEnvironment(policy: missingPolicy) {
            "Parent router authority is missing for \(String(describing: Parent.self)) while composing feature \(mapping.namespace)."
        }
        return content()
    }
}
