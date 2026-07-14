import Foundation
import OSLog

import InnoRouterCore

/// Registers a modal middleware for `ModalStore` initialization.
public struct ModalMiddlewareRegistration<M: Route>: Sendable {
    /// Middleware instance to register.
    public let middleware: AnyModalMiddleware<M>
    /// Optional debug label used in telemetry and diagnostics.
    public let debugName: String?

    /// Creates a middleware registration.
    public init(
        middleware: AnyModalMiddleware<M>,
        debugName: String? = nil
    ) {
        self.middleware = middleware
        self.debugName = debugName
    }
}

/// Debug metadata for a registered modal middleware.
public struct ModalMiddlewareMetadata: Equatable, Sendable {
    /// Stable handle used for future mutation operations.
    public let handle: ModalMiddlewareHandle
    /// Optional debug label associated with the middleware.
    public let debugName: String?

    /// Creates middleware metadata.
    public init(
        handle: ModalMiddlewareHandle,
        debugName: String? = nil
    ) {
        self.handle = handle
        self.debugName = debugName
    }
}

/// Outcome of a `ModalStore.execute(_:)` call surfaced through
/// `ModalEvent.commandIntercepted(command:result:)` and returned from the
/// public execute API.
public enum ModalExecutionResult<M: Route>: Sendable, Equatable {
    /// The command executed and mutated store state. `command` is the
    /// post-interception command (possibly rewritten by middleware).
    case executed(ModalCommand<M>)
    /// `.present` admitted but another modal is already active; the
    /// presentation was appended to the queue.
    case queued(ModalPresentation<M>)
    /// Middleware cancelled the command.
    case cancelled(ModalCancellationReason<M>)
    /// The command was a no-op (e.g. `.dismissCurrent` with no active modal).
    case noop
}

/// Outcome of a `ModalStore.present(_:style:)` call.
///
/// Mirrors `ModalExecutionResult` but specialised for the `.present`
/// command shape — callers do not need to inspect arbitrary command
/// payloads to know whether a presentation reached the screen,
/// was deferred behind an existing one, or was rewritten into a
/// non-presentation command.
///
/// The result is `@discardableResult`, so call sites that do not care
/// about the queued/shown distinction continue to compile unchanged.
public enum ModalPresentResult<M: Route>: Sendable, Equatable {
    /// The request produced the current presentation immediately.
    /// This covers both the no-active-presentation path and middleware
    /// rewrites that execute `.replaceCurrent`; `ModalStore.presentResult(from:)`
    /// maps both to `ModalPresentResult.shownImmediately`. The associated `id`
    /// is the effective current presentation's stable identifier.
    case shownImmediately(id: UUID)
    /// Another presentation was already active, so the request was
    /// appended to the queue. The presentation will surface once
    /// `dismissCurrent` clears the active modal.
    case queuedBehind(id: UUID)
    /// Middleware cancelled the command before it reached the store.
    case cancelled(ModalCancellationReason<M>)
    /// Middleware rewrote the `.present` request into a command that
    /// executed but did not produce a new presentation. Store state may
    /// still have changed (for example, a dismiss command may have
    /// cleared or promoted modal state).
    case rewrittenWithoutPresentation(command: ModalCommand<M>)
    /// The effective command was treated as a no-op by the store.
    /// For example, middleware can rewrite `.present` to
    /// `.replaceCurrent` when no modal is active.
    case noop

    /// Whether the presentation became the active modal immediately.
    public var isShownImmediately: Bool {
        if case .shownImmediately = self { return true }
        return false
    }

    /// Whether the presentation was appended to the queue.
    public var isQueuedBehind: Bool {
        if case .queuedBehind = self { return true }
        return false
    }

    /// The presentation's identifier when the request was admitted
    /// (either shown immediately or queued). `nil` for cancelled,
    /// rewritten non-presentation, or no-op outcomes.
    public var presentationID: UUID? {
        switch self {
        case .shownImmediately(let id), .queuedBehind(let id):
            return id
        case .cancelled, .rewrittenWithoutPresentation, .noop:
            return nil
        }
    }
}

/// Configuration for `ModalStore` observability, middleware, and logging.
///
/// Stored properties are `public var` so call sites can adjust the unified
/// observation hook after construction without re-stating every other
/// parameter — see ``NavigationStoreConfiguration`` for the same pattern.
public struct ModalStoreConfiguration<M: Route>: Sendable {
    /// Optional logger used by the default OSLog telemetry adapter and
    /// internal execution traces.
    public var logger: Logger?
    /// Structured telemetry sink used for modal lifecycle events.
    ///
    /// When this is `nil` and `logger` is supplied, ``ModalStore``
    /// installs ``OSLogModalTelemetrySink`` as the default adapter.
    /// Provide this sink when telemetry should go to analytics, tests,
    /// or another structured pipeline instead of OSLog.
    public var telemetrySink: AnyModalTelemetrySink<M>?
    /// Initial middleware registrations applied at store construction time.
    public var middlewares: [ModalMiddlewareRegistration<M>]
    /// Called synchronously for every public modal observation event.
    ///
    /// The callback receives presentations, dismissals, replacements, queue
    /// changes, command interception outcomes, and successful middleware
    /// mutations through a single ``ModalEvent`` value. Invalid middleware
    /// mutations do not emit events.
    public var onEvent: (@MainActor @Sendable (ModalEvent<M>) -> Void)?
    /// Backpressure policy applied to each subscriber of ``ModalStore/events``.
    ///
    /// Defaults to ``EventBufferingPolicy/default``. Opt into
    /// ``EventBufferingPolicy/unbounded`` when a deterministic test harness
    /// needs every emitted event.
    public var eventBufferingPolicy: EventBufferingPolicy
    /// Policy applied to ``ModalStore/queuedPresentations`` when a
    /// ``ModalMiddleware`` cancels a command.
    ///
    /// Defaults to ``ModalQueueCancellationPolicy/preserve`` — the
    /// historical 4.x behaviour. Switch to ``ModalQueueCancellationPolicy/dropQueued``
    /// or supply a ``ModalQueueCancellationPolicy/custom(_:)`` closure
    /// when an app interprets a cancelled command as also voiding the
    /// queued backlog. The active presentation is never touched by this
    /// policy — it only governs the queue.
    public var queueCancellationPolicy: ModalQueueCancellationPolicy<M>

    /// Creates a modal store configuration.
    public init(
        logger: Logger? = nil,
        telemetrySink: AnyModalTelemetrySink<M>? = nil,
        middlewares: [ModalMiddlewareRegistration<M>] = [],
        onEvent: (@MainActor @Sendable (ModalEvent<M>) -> Void)? = nil,
        eventBufferingPolicy: EventBufferingPolicy = .default,
        queueCancellationPolicy: ModalQueueCancellationPolicy<M> = .preserve
    ) {
        self.logger = logger
        self.telemetrySink = telemetrySink
        self.middlewares = middlewares
        self.onEvent = onEvent
        self.eventBufferingPolicy = eventBufferingPolicy
        self.queueCancellationPolicy = queueCancellationPolicy
    }
}
