import SwiftUI

extension EnvironmentValues {
    /// The policy applied when ``EnvironmentRouter`` cannot resolve the
    /// requested route authority or capability in the current view tree.
    @Entry public var innoRouterEnvironmentMissingPolicy: EnvironmentMissingPolicy = .crash
}

extension View {
    /// Overrides the policy for unresolved ``EnvironmentRouter`` actions.
    ///
    /// ```swift
    /// #Preview {
    ///     SomeFeatureView()
    ///         .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
    /// }
    /// ```
    @MainActor
    public func innoRouterEnvironmentMissingPolicy(
        _ policy: EnvironmentMissingPolicy
    ) -> some View {
        environment(\.innoRouterEnvironmentMissingPolicy, policy)
    }
}
