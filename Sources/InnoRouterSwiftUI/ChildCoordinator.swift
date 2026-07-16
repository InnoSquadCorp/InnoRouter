import Synchronization

private final class ChildCoordinatorHandoff<Result: Sendable>: Sendable {
    enum Resolution: Sendable {
        case finished(Result)
        case childCancelled
        case parentCancelled
    }

    private struct State {
        var resolution: Resolution?
        var continuation: CheckedContinuation<Resolution, Never>?
    }

    private let state = Mutex(State())

    func resolve(_ resolution: Resolution) {
        let continuation = state.withLock { state -> CheckedContinuation<Resolution, Never>? in
            guard state.resolution == nil else {
                return nil
            }

            state.resolution = resolution
            defer { state.continuation = nil }
            return state.continuation
        }

        continuation?.resume(returning: resolution)
    }

    func waitForResolution() async -> Resolution {
        await withCheckedContinuation { continuation in
            let resolved = state.withLock { state -> Resolution? in
                if let resolution = state.resolution {
                    return resolution
                }

                precondition(
                    state.continuation == nil,
                    "A ChildCoordinator handoff can only be awaited once."
                )
                state.continuation = continuation
                return nil
            }

            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }
}

/// A coordinator that reports completion back to a parent with a typed result.
///
/// Use ``waitForResult()`` to await a child flow's outcome without
/// hand-wiring closures per call site. The child is
/// responsible for invoking ``onFinish`` exactly once on success or
/// ``onCancel`` on dismissal; subsequent callback firings are ignored.
///
/// Child lifetimes are orchestrated at the coordinator layer — the
/// asynchronous result wait owns the strong reference until it resolves.
/// See `Docs/design-child-coordinator-handoff.md` for the full contract.
///
@MainActor
public protocol ChildCoordinator: AnyObject {
    associatedtype Result: Sendable

    /// Called by the child to report a successful completion.
    var onFinish: (@MainActor @Sendable (Result) -> Void)? { get set }

    /// Called by the child to report cancellation or user-driven dismissal.
    var onCancel: (@MainActor @Sendable () -> Void)? { get set }

    /// Called on the main actor when the task awaiting
    /// ``waitForResult()`` is cancelled (e.g. the parent's
    /// view is torn down, the parent receives its own
    /// `parentDidCancel`, or the app explicitly cancels the task).
    ///
    /// Default implementation is a no-op — conforming coordinators
    /// override this when they need to tear down transient state
    /// triggered by the parent handoff (dismiss sheets, cancel
    /// in-flight work, release temporary stores, etc.). Keep any
    /// app-owned `Task` handles on the child and cancel them here.
    ///
    /// The callback is directional: `parentDidCancel` flows
    /// **parent → child**. Use `onCancel` when the child itself
    /// wants to abort (child → parent). The two hooks are
    /// orthogonal; firing one does not invoke the other.
    ///
    /// The result-wait helper invokes this method exactly once, as part of
    /// its `withTaskCancellationHandler` recovery path. Repeated
    /// invocations are not expected, but the default no-op makes
    /// idempotency a safe assumption.
    @MainActor
    func parentDidCancel()
}

public extension ChildCoordinator {
    /// Default no-op. Override to tear down transient state when the
    /// calling task is cancelled.
    func parentDidCancel() {}
}

public extension ChildCoordinator {
    /// Installs completion callbacks and suspends until this child finishes,
    /// returning its result or `nil` on cancellation.
    ///
    /// The caller is responsible for placing the child's view in its tree
    /// (push, sheet, cover) and for tearing that placement down after the
    /// asynchronous call resolves. This API covers **result propagation
    /// only**; the child's view lifecycle is deliberately not automated.
    ///
    /// Concurrently awaiting the same child instance is unsupported. This
    /// method fails fast when callbacks have already been installed by
    /// another handoff.
    ///
    /// Callbacks are installed before this method first suspends, so it is
    /// safe for the child to fire `onFinish` or `onCancel` at any point
    /// after the asynchronous call begins. Subsequent callback firings are
    /// ignored, and the installed callbacks are removed before this method
    /// returns.
    ///
    /// When the calling task is cancelled, the child's
    /// ``ChildCoordinator/parentDidCancel()`` method is invoked on the main
    /// actor and this method resolves with `nil`. Cancellation and child
    /// completion race through a single first-writer-wins handoff, so only
    /// one terminal outcome is observed.
    @MainActor
    func waitForResult() async -> Result? {
        precondition(
            onFinish == nil && onCancel == nil,
            "Cannot wait for a ChildCoordinator result while completion callbacks are already installed."
        )

        let previousOnFinish = onFinish
        let previousOnCancel = onCancel
        let handoff = ChildCoordinatorHandoff<Result>()

        // The deferred restoration deliberately references `self`, keeping
        // even an inline temporary coordinator alive for the full handoff.
        defer {
            onFinish = previousOnFinish
            onCancel = previousOnCancel
        }

        let resolution = await withTaskCancellationHandler {
            // Register cancellation before installing callbacks so an
            // already-cancelled caller wins even when a callback setter
            // synchronously reports a child result.
            if Task.isCancelled {
                handoff.resolve(.parentCancelled)
            }

            onFinish = { result in
                handoff.resolve(.finished(result))
            }
            onCancel = {
                handoff.resolve(.childCancelled)
            }

            return await handoff.waitForResolution()
        } onCancel: {
            handoff.resolve(.parentCancelled)
        }

        switch resolution {
        case let .finished(result):
            return result
        case .childCancelled:
            return nil
        case .parentCancelled:
            parentDidCancel()
            return nil
        }
    }
}
