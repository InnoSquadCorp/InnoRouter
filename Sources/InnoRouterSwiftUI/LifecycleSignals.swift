// MARK: - LifecycleSignals.swift
// InnoRouterSwiftUI - cross-cutting coordinator lifecycle signals
// Copyright © 2026 Inno Squad. All rights reserved.
//
// `Coordinator`, `StepCoordinator`, `TabCoordinator`, and
// `ChildCoordinator` each have lifecycle moments that benefit
// from a shared signal bag: parent-driven cancellation, host-
// driven teardown, etc. `LifecycleSignals` is the value-typed
// bag of optional `@MainActor @Sendable` callbacks every
// coordinator type can install once at init and trigger
// uniformly through the `LifecycleAware` capability protocol.
//
// `ChildCoordinator` adopts `LifecycleAware` unconditionally
// because `ChildCoordinator.waitForResult()` fires
// `lifecycleSignals.fireParentCancel()` on parent task
// cancellation. Other coordinator types opt in case-by-case
// when a host wants to drive `lifecycleSignals.fireTeardown()`
// from its own release path.

import Foundation

/// A bag of optional, fire-and-forget lifecycle callbacks shared
/// across coordinator types via the ``LifecycleAware`` capability
/// protocol.
///
/// As of 5.0 the SDK routes the following signals through this
/// bag (more may be added in subsequent minors):
///
/// - ``onParentCancel`` — fired when a parent task cancels.
///   `ChildCoordinator.waitForResult()` calls this on the child after
///   invoking ``ChildCoordinator/parentDidCancel()``.
/// - ``onTeardown`` — fired when the owning coordinator is
///   released so transient resources (subscriptions, timers,
///   in-flight network requests) can be cancelled. Hosts and
///   coordinator-owning code call this from their teardown path.
///
/// Both callbacks are `@MainActor @Sendable` because every current
/// coordinator surface is `@MainActor`-isolated.
@MainActor
public struct LifecycleSignals: Sendable {

    /// Invoked when a caller task cancels. `ChildCoordinator.waitForResult()`
    /// fires this through the child's ``LifecycleAware/lifecycleSignals``.
    public var onParentCancel: (@MainActor @Sendable () -> Void)?

    /// Invoked when the owning coordinator is being released so
    /// transient state (subscriptions, timers, in-flight network
    /// requests) can be cancelled.
    public var onTeardown: (@MainActor @Sendable () -> Void)?

    public init(
        onParentCancel: (@MainActor @Sendable () -> Void)? = nil,
        onTeardown: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.onParentCancel = onParentCancel
        self.onTeardown = onTeardown
    }

    /// Fires the ``onParentCancel`` handler if installed.
    public func fireParentCancel() {
        onParentCancel?()
    }

    /// Fires the ``onTeardown`` handler if installed.
    public func fireTeardown() {
        onTeardown?()
    }
}

/// Capability protocol for any coordinator that wants to expose
/// lifecycle signals through the unified ``LifecycleSignals`` bag.
///
/// `ChildCoordinator` requires this conformance because the parent
/// result-wait helper fires ``LifecycleSignals/fireParentCancel()`` on
/// task cancellation. Other coordinator types (`Coordinator`,
/// `StepCoordinator`, `TabCoordinator`) opt in by adopting
/// `LifecycleAware` directly and declaring a
/// ``lifecycleSignals`` storage property.
@MainActor
public protocol LifecycleAware: AnyObject {
    /// The lifecycle-signals bag installed on this coordinator.
    /// Must be `var` so producers (push helpers, host teardown
    /// paths, future signal dispatchers) can mutate the installed
    /// handlers.
    var lifecycleSignals: LifecycleSignals { get set }
}
