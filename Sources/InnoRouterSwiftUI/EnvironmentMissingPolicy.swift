import OSLog
import SwiftUI

/// Controls how ``EnvironmentRouter`` actions respond when the
/// matching `NavigationHost` / `CoordinatorHost` / `ModalHost` /
/// `FlowHost` environment is not in scope.
///
/// The default is ``crash`` so production builds catch missing
/// environment wiring on the first attempted router action.
/// SwiftUI Previews, snapshot tests, and other host-less rendering
/// paths can override the default through the
/// ``SwiftUI/View/innoRouterEnvironmentMissingPolicy(_:)`` modifier
/// to keep rendering instead of trapping.
///
/// `logAndDegrade` skips the unavailable action and emits a
/// `Logger.error` line so the missing wiring is still visible in
/// the console without aborting the process.
///
/// `assertAndLog` traps in Debug builds (catching the wiring bug
/// during development) but logs and skips the unavailable action in
/// Release. Use this when ``crash`` feels too aggressive for
/// production cold-starts but ``logAndDegrade`` is too quiet during
/// development.
public enum EnvironmentMissingPolicy: Sendable, Hashable {
    /// Trap with `preconditionFailure` when the environment is
    /// missing. Default behaviour.
    case crash
    /// Log an error and skip the unavailable action so
    /// the surrounding view tree can keep rendering. Intended for
    /// SwiftUI Previews, host-less snapshot tests, and similar
    /// out-of-app contexts.
    case logAndDegrade
    /// Log an error and trap with `assertionFailure` so Debug builds
    /// catch the missing wiring while Release builds keep rendering
    /// without performing the action. Useful when shipping a pre-launch
    /// build where a stray missing host should not crash the app but
    /// must still surface during development.
    case assertAndLog
}

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

// MARK: - Internal helpers

@MainActor
let environmentMissingLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "environment-missing"
)

@MainActor
func handleMissingEnvironment(
    policy: EnvironmentMissingPolicy,
    message: () -> String
) {
    switch policy {
    case .crash:
        preconditionFailure(message())
    case .logAndDegrade:
        let resolved = message()
        environmentMissingLogger.error("\(resolved, privacy: .public)")
    case .assertAndLog:
        let resolved = message()
        environmentMissingLogger.error("\(resolved, privacy: .public)")
        assertionFailure(resolved)
    }
}
