/// The outcome of executing a ``NavigationCommand`` against a ``RouteStack``.
///
/// Results are layered into three groups so callers can react without
/// re-parsing the case payload:
///
/// 1. **Success** — ``isSuccess`` returns `true` for ``success`` and for
///    ``multiple(_:)`` whose every nested result is itself successful.
///    An **empty** ``multiple(_:)`` is deliberately *not* a success: an
///    empty composite (`.sequence([])`, an empty batch) means the caller
///    requested nothing, which is treated as a programming error rather
///    than a vacuous success. This differs from concrete commands with
///    empty payloads — `.pushAll([])` is a successful no-op and
///    `.replace([])` successfully clears the stack — because those
///    describe a real (if trivial) target state, while an empty composite
///    describes no work at all.
/// 2. **Engine failures** — ``isEngineFailure`` returns `true` for the
///    deterministic stack rejections (``emptyStack``, ``invalidPopCount(_:)``,
///    ``insufficientStackDepth(requested:available:)``, ``routeNotFound(_:)``).
///    These are produced inside ``NavigationEngine`` and never reach
///    middleware.
/// 3. **Middleware cancellations** — ``isMiddlewareCancellation`` returns
///    `true` when a registered middleware vetoed the command via
///    ``NavigationCancellationReason/middleware(debugName:command:)``.
///    Use ``middlewareCancellationReason`` to surface the human-readable
///    debug label for telemetry.
public enum NavigationResult<R: Route>: Sendable, Equatable {
    case success
    case cancelled(NavigationCancellationReason<R>)
    case emptyStack
    case invalidPopCount(Int)
    case insufficientStackDepth(requested: Int, available: Int)
    case routeNotFound(R)
    case multiple([NavigationResult<R>])

    public var isSuccess: Bool {
        switch self {
        case .success: true
        case .multiple(let results): !results.isEmpty && results.allSatisfy(\.isSuccess)
        default: false
        }
    }

    /// Returns `true` when the result represents an engine-level rejection —
    /// stack underflow, missing pop target, or invalid pop count. Engine
    /// failures are deterministic and are reported even when no middleware
    /// is registered.
    ///
    /// For ``multiple(_:)`` the property returns `true` if **any** nested
    /// step is itself an engine failure.
    public var isEngineFailure: Bool {
        switch self {
        case .emptyStack, .invalidPopCount, .insufficientStackDepth, .routeNotFound:
            return true
        case .multiple(let results):
            return results.contains(where: \.isEngineFailure)
        case .success, .cancelled:
            return false
        }
    }

    /// Returns `true` when the result represents a middleware cancellation
    /// (i.e. ``cancelled(_:)`` whose reason is
    /// ``NavigationCancellationReason/middleware(debugName:command:)``).
    /// Other cancellation reasons (``conditionFailed``, ``custom(_:)``,
    /// ``staleAfterPrepare(command:)``) are **not** counted as middleware
    /// cancellations because they don't originate from a registered
    /// middleware veto.
    ///
    /// For ``multiple(_:)`` the property returns `true` if **any** nested
    /// step was cancelled by middleware.
    public var isMiddlewareCancellation: Bool {
        switch self {
        case .cancelled(.middleware):
            return true
        case .multiple(let results):
            return results.contains(where: \.isMiddlewareCancellation)
        default:
            return false
        }
    }

    /// The middleware's debug label when the result is a
    /// ``NavigationCancellationReason/middleware(debugName:command:)``
    /// cancellation, otherwise `nil`. The label is exactly the
    /// `debugName` registered with the middleware and may itself be `nil`
    /// when the middleware was registered anonymously.
    ///
    /// For ``multiple(_:)`` the property returns the first non-`nil`
    /// label found in the sequence. Use this for telemetry breadcrumbs;
    /// for branching logic prefer ``isMiddlewareCancellation`` paired with
    /// switching over the underlying ``NavigationCancellationReason``.
    public var middlewareCancellationReason: String? {
        switch self {
        case .cancelled(.middleware(let debugName, _)):
            return debugName
        case .multiple(let results):
            for result in results {
                if let label = result.middlewareCancellationReason {
                    return label
                }
            }
            return nil
        default:
            return nil
        }
    }
}
