import SwiftUI

/// A coordinator that reports completion back to a parent with a typed result.
///
/// Used together with ``Coordinator/push(child:)`` to await a child flow's
/// outcome without hand-wiring closures per call site. The child is
/// responsible for invoking ``onFinish`` exactly once on success or
/// ``onCancel`` on dismissal; subsequent callback firings are ignored.
///
/// Child lifetimes are orchestrated at the coordinator layer — the
/// parent owns the strong reference until the returned `Task` resolves.
/// See `Docs/design-child-coordinator-handoff.md` for the full contract.
///
/// A child also carries a ``lifecycleSignals`` bag (via
/// ``LifecycleAware``) — the parent push helper fires
/// ``LifecycleSignals/fireParentCancel()`` alongside the legacy
/// ``parentDidCancel()`` hook so app code can install teardown
/// handlers without overriding the protocol method.
@MainActor
public protocol ChildCoordinator: LifecycleAware {
    associatedtype Result: Sendable

    /// Called by the child to report a successful completion.
    var onFinish: (@MainActor @Sendable (Result) -> Void)? { get set }

    /// Called by the child to report cancellation or user-driven dismissal.
    var onCancel: (@MainActor @Sendable () -> Void)? { get set }

    /// Called on the main actor when the parent `Task` awaiting
    /// ``Coordinator/push(child:)`` is cancelled (e.g. the parent's
    /// view is torn down, the parent receives its own
    /// `parentDidCancel`, or the app explicitly cancels the task).
    ///
    /// Default implementation is a no-op — conforming coordinators
    /// override this when they need to tear down transient state
    /// triggered by the parent push (dismiss sheets, cancel
    /// in-flight work, release temporary stores, etc.). Keep any
    /// app-owned `Task` handles on the child and cancel them here, or
    /// install the same cleanup on ``lifecycleSignals``.
    ///
    /// The callback is directional: `parentDidCancel` flows
    /// **parent → child**. Use `onCancel` when the child itself
    /// wants to abort (child → parent). The two hooks are
    /// orthogonal; firing one does not invoke the other.
    ///
    /// The push helper invokes this method exactly once, as part of
    /// its `withTaskCancellationHandler` recovery path. Repeated
    /// invocations are not expected, but the default no-op makes
    /// idempotency a safe assumption.
    @MainActor
    func parentDidCancel()
}

public extension ChildCoordinator {
    /// Default no-op. Override to tear down transient state when the
    /// parent `Task` is cancelled.
    func parentDidCancel() {}
}

public extension Coordinator {
    /// Installs completion callbacks on the given child and returns a Task
    /// that resolves with the child's result, or `nil` on cancellation.
    ///
    /// The parent is responsible for placing the child's view in its tree
    /// (push, sheet, cover) and for tearing that placement down after the
    /// Task resolves. This API covers **result propagation only**; the
    /// child's view lifecycle is deliberately not automated.
    ///
    /// Reusing the same child instance is unsupported. This method fails
    /// fast when callbacks have already been installed on `child`.
    ///
    /// Callbacks are installed synchronously before the returned Task
    /// begins awaiting, so it is safe for the child to fire `onFinish`
    /// or `onCancel` at any point after this call — even before the
    /// parent's `await`. Subsequent callback firings are ignored.
    ///
    /// When the returned `Task` is cancelled (either via
    /// `task.cancel()` or by cancellation of a surrounding
    /// `Task.cancel()`), the child's ``ChildCoordinator/parentDidCancel()``
    /// method is invoked on the main actor and the underlying
    /// continuation is finished, so the task's `await` resolves
    /// with `nil`.
    @MainActor
    @discardableResult
    func push<Child: ChildCoordinator>(
        child: Child
    ) -> Task<Child.Result?, Never> {
        precondition(
            child.onFinish == nil && child.onCancel == nil,
            "Cannot push the same ChildCoordinator instance more than once."
        )
        let (stream, continuation) = AsyncStream<Child.Result?>.makeStream()
        child.onFinish = { result in
            continuation.yield(result)
            continuation.finish()
        }
        child.onCancel = {
            continuation.yield(nil)
            continuation.finish()
        }
        // Capture the cancel signal as a pre-bound @Sendable closure
        // so the task-cancellation handler can hop back to the main
        // actor without crossing isolation with a raw `Child`
        // reference (which is non-Sendable AnyObject). The closure
        // fires both signals — the `parentDidCancel()` protocol
        // method and the `lifecycleSignals.onParentCancel` handler
        // — so adopters can opt for either teardown style.
        let invokeParentDidCancel: @Sendable @MainActor () -> Void = { [weak child] in
            guard let child else { return }
            child.parentDidCancel()
            child.lifecycleSignals.fireParentCancel()
        }
        return Task {
            await withTaskCancellationHandler {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() ?? nil
            } onCancel: {
                // Fire the directional signal on the main actor and
                // unblock the iterator so the Task exits cleanly with
                // `nil`. A weak child capture keeps us safe if the
                // parent has released the child in the meantime.
                Task { @MainActor in
                    invokeParentDidCancel()
                }
                continuation.finish()
            }
        }
    }
}
