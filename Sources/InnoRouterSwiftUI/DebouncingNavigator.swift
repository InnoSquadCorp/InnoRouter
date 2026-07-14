import Foundation
import OSLog

import InnoRouterCore

private let debouncingNavigatorLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "debouncing-navigator"
)

/// Wraps a `Navigator` with "fire the latest command after a quiet
/// period" semantics — the canonical debounce pattern.
///
/// Calling ``debouncedExecute(_:)`` schedules the command to run on
/// the inner navigator after ``interval`` of clock-time inactivity.
/// A second ``debouncedExecute(_:)`` arriving inside the interval
/// cancels the pending fire and starts a fresh window with the new
/// command. Only the latest command in a quiet window ever reaches
/// the navigator.
///
/// Debounce semantics intentionally live outside `NavigationEngine`
/// (which is synchronous and `Clock`-free) and outside
/// `NavigationMiddleware` (which cannot reliably re-dispatch the
/// deferred command without creating a loop). A wrapping navigator
/// is the right abstraction:
///
/// ```swift
/// let store = NavigationStore<AppRoute>()
/// let debouncing = DebouncingNavigator(
///     wrapping: store,
///     interval: .milliseconds(300),
///     clock: ContinuousClock()
/// )
/// await debouncing.debouncedExecute(.push(.detail))
/// ```
///
/// Unlike `ThrottleNavigationMiddleware` (which cancels in-window
/// commands at interception time), `DebouncingNavigator` accepts
/// every command and simply delays execution until the window
/// elapses. The clock is generic so deterministic test clocks
/// work.
@MainActor
public final class DebouncingNavigator<
    N: NavigationCommandExecutor,
    C: Clock
> where C.Duration == Duration {

    /// Inner navigator the deferred command ultimately executes
    /// against once the quiet window elapses.
    public let inner: N

    private let interval: Duration
    private let clock: C
    private var pendingTask: Task<NavigationResult<N.RouteType>?, Never>?
    private var pendingTaskGeneration = 0

    /// - Parameters:
    ///   - inner: The destination navigator commands ultimately
    ///     execute against once the quiet window elapses.
    ///   - interval: How long the navigator waits after a call
    ///     before firing the most recent command.
    ///   - clock: Clock used to measure the interval. Inject a
    ///     test clock to make timing deterministic.
    public init(
        wrapping inner: N,
        interval: Duration,
        clock: C
    ) {
        self.inner = inner
        self.interval = interval
        self.clock = clock
    }

    /// Schedules `command` to fire after ``interval`` of quiet time.
    /// If another `debouncedExecute(_:)` arrives within that window,
    /// the previous schedule is cancelled and the new command takes
    /// its place.
    ///
    /// - Returns: The `NavigationResult` produced by the inner
    ///   navigator, or `nil` if a subsequent
    ///   `debouncedExecute(_:)` superseded this one before it
    ///   could fire.
    @discardableResult
    public func debouncedExecute(
        _ command: NavigationCommand<N.RouteType>
    ) async -> NavigationResult<N.RouteType>? {
        pendingTask?.cancel()
        pendingTaskGeneration += 1
        let generation = pendingTaskGeneration

        let interval = self.interval
        let clock = self.clock
        let inner = self.inner

        let task = Task<NavigationResult<N.RouteType>?, Never> { @MainActor in
            do {
                try await clock.sleep(for: interval)
            } catch is CancellationError {
                return nil
            } catch {
                let description = String(describing: error)
                debouncingNavigatorLogger.error(
                    "DebouncingNavigator sleep failed with non-cancellation error: \(description, privacy: .private(mask: .hash))"
                )
                assertionFailure("DebouncingNavigator sleep failed with non-cancellation error: \(error)")
                return nil
            }
            if Task.isCancelled {
                return nil
            }
            return inner.execute(command)
        }
        pendingTask = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if pendingTaskGeneration == generation {
            pendingTask = nil
        }
        return result
    }

    /// Cancels any pending debounced command without firing it.
    /// Useful in `onDisappear` paths where the call site wants to
    /// abandon a queued navigation.
    public func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingTaskGeneration += 1
    }
}

public extension DebouncingNavigator where C == ContinuousClock {
    /// Convenience initialiser using the default `ContinuousClock`.
    convenience init(
        wrapping inner: N,
        interval: Duration
    ) {
        self.init(wrapping: inner, interval: interval, clock: ContinuousClock())
    }
}
