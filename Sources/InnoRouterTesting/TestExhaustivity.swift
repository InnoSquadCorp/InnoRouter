// MARK: - TestExhaustivity.swift
// InnoRouterTesting - strictness mode for host-less test stores
// Copyright © 2026 Inno Squad. All rights reserved.

/// Controls how strictly a test store checks pending events when observation
/// finishes.
///
/// InnoRouter's test stores follow TCA's `TestStore` exhaustivity model:
/// events collected from the underlying authority's unified `onEvent`
/// callback accumulate in an internal queue. Each
/// `receive(...)` call dequeues the next event and asserts a predicate. In
/// In `.strict` mode, the store reports events left pending at `finish()` or
/// deallocation.
/// `assertNoPendingEvents()` is a non-terminal checkpoint: it reports and
/// consumes the current pending snapshot, then continues observing. `finish()`
/// closes the queue, consumes its final snapshot, and reports the first event
/// emitted after that boundary in both exhaustivity modes.
///
/// > Note: Swift Testing currently attributes issues recorded inside an
/// > isolated `deinit` to an *unknown test* rather than to the test that
/// > owned the store, which makes a deinit-time leftover-event failure
/// > hard to locate. Until that is resolved upstream, await all work and end
/// > each test with an explicit `finish()`. It runs the strict check with the
/// > caller's source location and disarms the deinit-time fallback.
public enum TestExhaustivity: Sendable, Equatable {
    /// Every observed event must be drained through `receive(...)` before
    /// `finish()` or deallocation. Pending events fail the test. This is the
    /// default and matches TCA's `exhaustive` semantics.
    case strict

    /// The test store still delivers events through `receive(...)`, but pending
    /// events at `finish()` or deallocation are silently discarded. Explicit
    /// assertions and events emitted after `finish()` still report issues.
    /// Useful for incremental migrations of large legacy suites.
    case off
}
