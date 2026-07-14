import InnoRouterCore

/// Public observation payload delivered whenever a SwiftUI path update cannot
/// be reconciled structurally with the current `RouteStack` and the configured
/// `NavigationPathMismatchPolicy` resolves the divergence.
///
/// `NavigationStore` already emits internal telemetry for every path mismatch;
/// this type exposes the same signal through a public configuration hook so
/// apps can feed analytics pipelines (for instance, to detect
/// swipe-back-while-pushing races) without reaching for `@testable import`.
///
/// Successful prefix reductions — a plain pop or stack truncation — do **not**
/// emit this event. Only mismatches that required the policy to synthesize a
/// reconciliation strategy are reported here.
public struct NavigationPathMismatchEvent<R: Route>: Equatable, Sendable {
    /// Categorises which policy resolved the mismatch.
    public enum Policy: String, Equatable, Sendable {
        /// `.replace` — silently replaces the stack with the incoming path.
        case replace
        /// `.assertAndReplace` — traps in debug builds, replaces in release.
        case assertAndReplace
        /// `.ignore` — ignores the SwiftUI update and restores the binding.
        case ignore
        /// Custom policy supplied by the app.
        case custom
    }

    /// Describes what the policy resolved the mismatch into.
    public enum Resolution: Equatable, Sendable {
        /// The policy resolved the mismatch into a single command.
        case single(NavigationCommand<R>)
        /// The policy resolved the mismatch into a batch of commands.
        case batch([NavigationCommand<R>])
        /// The policy decided to ignore the mismatch.
        case ignore
    }

    /// The policy that resolved this mismatch.
    public let policy: Policy

    /// How the policy chose to reconcile the mismatch.
    public let resolution: Resolution

    /// The stack path before the SwiftUI binding update.
    public let oldPath: [R]

    /// The SwiftUI-supplied path that triggered the mismatch.
    public let newPath: [R]
}
