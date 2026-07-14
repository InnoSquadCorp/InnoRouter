// MARK: - ThrottleNavigationMiddleware.swift
// InnoRouterSwiftUI - rate-limit navigation commands via middleware
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import InnoRouterCore

/// Cancels `NavigationCommand`s that arrive within a `minimumInterval`
/// of a previously-accepted command sharing the same `Key`. Useful for
/// "dedupe rapid taps" UX patterns without asking every call site to
/// track timestamps manually.
///
/// Throttle decisions are synchronous at interception time, but the
/// last-accept timestamp is only committed after a successful
/// execution. That keeps the middleware concurrency-free and lets
/// `NavigationEngine` stay `Clock`-free while still matching the
/// documented "previously accepted command" semantics. (`.debounce`
/// semantics — "wait, then dispatch the latest" — require a timer +
/// cancellable `Task` and are intentionally deferred.)
///
/// The middleware is generic over `Clock`, so tests can inject a
/// deterministic clock:
///
/// ```swift
/// let clock = TestClock()
/// store.addMiddleware(
///     AnyNavigationMiddleware(
///         ThrottleNavigationMiddleware<AppRoute>(
///             interval: .milliseconds(300),
///             clock: clock
///         )
///     ),
///     debugName: "throttle"
/// )
/// ```
@MainActor
public final class ThrottleNavigationMiddleware<
    R: Route,
    C: Clock
>: NavigationMiddleware where C.Duration == Duration {

    public typealias RouteType = R

    /// Identifies which commands share a throttle window. Returning
    /// `nil` from the key closure opts a command out of throttling
    /// entirely. Users supply the string key so the throttle
    /// granularity matches the app's UX intent ("any push", "push per
    /// route", "navigation-wide", …).
    public typealias Key = String

    /// Reserved key for global throttling across every command.
    public static var globalKey: Key { "__throttle__all" }

    private let interval: Duration
    private let clock: C
    private let keyFor: @MainActor @Sendable (NavigationCommand<R>) -> Key?
    private var lastAccept: [Key: C.Instant] = [:]
    private var pendingAttempts: [PendingAttempt] = []

    private enum PendingAttempt {
        case bypass
        case rejected
        case candidate(key: Key, acceptedAt: C.Instant)
    }

    /// - Parameters:
    ///   - interval: Minimum time between two commands that share the
    ///     same key. Commands within `interval` of the last accept
    ///     get cancelled with `.middleware(debugName: nil, command: ...)`,
    ///     letting the registry fill in the registered debug name.
    ///   - clock: Clock used to query `now`. Defaults to
    ///     `ContinuousClock`; tests can inject a synthetic clock.
    ///   - key: Maps a command to the throttle key. Default groups
    ///     all commands under ``globalKey`` for a single global
    ///     window; return a command-specific key for per-command
    ///     throttling, or `nil` to opt a command out.
    public init(
        interval: Duration,
        clock: C,
        key: @escaping @MainActor @Sendable (NavigationCommand<R>) -> Key?
    ) {
        self.interval = interval
        self.clock = clock
        self.keyFor = key
    }

    public func willExecute(
        _ command: NavigationCommand<R>,
        state: RouteStack<R>
    ) -> NavigationInterception<R> {
        guard let key = keyFor(command) else {
            pendingAttempts.append(.bypass)
            return .proceed(command)
        }
        let now = clock.now
        if let last = lastAccept[key] {
            let elapsed = last.duration(to: now)
            if elapsed < interval {
                pendingAttempts.append(.rejected)
                return .cancel(.middleware(debugName: nil, command: command))
            }
        }
        pendingAttempts.append(.candidate(key: key, acceptedAt: now))
        return .proceed(command)
    }

    public func didExecute(
        _ command: NavigationCommand<R>,
        result: NavigationResult<R>,
        state: RouteStack<R>
    ) -> NavigationResult<R> {
        guard let pending = consumePendingAttempt() else {
            return result
        }

        if case .candidate(let key, let acceptedAt) = pending, result.isSuccess {
            lastAccept[key] = acceptedAt
        }
        return result
    }

    private func consumePendingAttempt() -> PendingAttempt? {
        guard !pendingAttempts.isEmpty else { return nil }
        return pendingAttempts.removeFirst()
    }
}

extension ThrottleNavigationMiddleware: NavigationMiddlewareDiscardCleanup {
    package func discardExecution(
        _ command: NavigationCommand<R>,
        result: NavigationResult<R>,
        state: RouteStack<R>
    ) {
        _ = consumePendingAttempt()
    }
}

public extension ThrottleNavigationMiddleware where C == ContinuousClock {
    /// Convenience initializer using the default `ContinuousClock`.
    /// Throttles all commands under the same global window.
    convenience init(interval: Duration) {
        self.init(
            interval: interval,
            clock: ContinuousClock(),
            key: { _ in Self.globalKey }
        )
    }

    /// Convenience with a per-command key closure using the default
    /// `ContinuousClock`.
    convenience init(
        interval: Duration,
        key: @escaping @MainActor @Sendable (NavigationCommand<R>) -> String?
    ) {
        self.init(interval: interval, clock: ContinuousClock(), key: key)
    }
}
