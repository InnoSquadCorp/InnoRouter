import Foundation

/// Logical execution domains used to correlate nested InnoRouter operations.
package enum InternalExecutionTraceDomain: String, Sendable, Equatable {
    /// Spans emitted by `NavigationStore` command execution and preview commit.
    case navigation
    /// Spans emitted by `ModalStore` preview commit and modal execution.
    case modal
    /// Spans emitted by `FlowStore` intent dispatch and plan application.
    case flow
    /// Spans emitted by deep-link pipeline handlers and pending-link replay.
    case deepLink
}

/// Context carried by each trace record for a single execution span.
///
/// `rootID` is created once for the outermost span in a task-local chain and
/// reused by every nested span. `spanID` is unique per `withSpan` invocation.
/// `parentSpanID` is the caller's active span when nesting occurs, or `nil`
/// for the root span.
package struct InternalExecutionTraceContext: Sendable, Equatable {
    /// Stable identifier shared by every span in the same traced operation tree.
    package let rootID: String
    /// Identifier unique to this specific span.
    package let spanID: String
    /// Parent span identifier when this span is nested inside another span.
    package let parentSpanID: String?
    /// Domain that emitted the span.
    package let domain: InternalExecutionTraceDomain

    /// Creates an explicit execution-trace context.
    package init(
        rootID: String,
        spanID: String,
        parentSpanID: String?,
        domain: InternalExecutionTraceDomain
    ) {
        self.rootID = rootID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.domain = domain
    }
}

/// Trace events emitted around the lifetime of a span.
package enum InternalExecutionTraceRecord: Sendable, Equatable {
    /// Emitted immediately before entering the traced body.
    case start(
        context: InternalExecutionTraceContext,
        operation: String,
        metadata: [String: String]
    )
    /// Emitted immediately after the traced body finishes and its outcome string is computed.
    case finish(
        context: InternalExecutionTraceContext,
        operation: String,
        outcome: String
    )
}

/// Main-actor recorder invoked for `start`/`finish` records around a span.
package typealias InternalExecutionTraceRecorder =
    @MainActor @Sendable (InternalExecutionTraceRecord) -> Void

/// Internal tracing helpers shared by stores and effect handlers.
package enum InternalExecutionTrace {
    /// Task-local root span identifier inherited by nested spans in the same task.
    @TaskLocal package static var currentRootID: String?
    /// Task-local active span identifier inherited by nested spans in the same task.
    @TaskLocal package static var currentSpanID: String?

    /// Runs a synchronous body inside a traced span on the main actor.
    ///
    /// Use this overload for non-async execution paths. The `outcome` closure is
    /// evaluated inside the span after `body` returns, and the recorder receives
    /// `.start` before execution and `.finish` after execution while task-local
    /// root/span identifiers are active for nested calls.
    ///
    /// `metadata` is `@autoclosure`d so call sites that build the dictionary
    /// from `String(describing:)` (the common case for command/preview
    /// arguments) pay zero cost when `recorder` is `nil`.
    @MainActor
    package static func withSpan<T>(
        domain: InternalExecutionTraceDomain,
        operation: String,
        recorder: InternalExecutionTraceRecorder?,
        metadata: @autoclosure () -> [String: String] = [:],
        _ body: () -> T,
        outcome: (T) -> String
    ) -> T {
        guard let recorder else {
            // Fast path: no recorder means no telemetry sink and no
            // logger, so the task-local span identifiers are the only
            // observable side effect. Skip metadata evaluation
            // entirely — the caller's `String(describing:)` work
            // never runs.
            return body()
        }

        let rootID = currentRootID ?? UUID().uuidString
        let parentSpanID = currentSpanID
        let spanID = UUID().uuidString
        let context = InternalExecutionTraceContext(
            rootID: rootID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            domain: domain
        )

        recorder(.start(context: context, operation: operation, metadata: metadata()))
        return $currentRootID.withValue(rootID) {
            $currentSpanID.withValue(spanID) {
                let value = body()
                recorder(.finish(context: context, operation: operation, outcome: outcome(value)))
                return value
            }
        }
    }

    /// Runs an asynchronous body inside a traced span on the main actor.
    ///
    /// Use this overload for async execution paths that must preserve root/span
    /// correlation across suspension points. The task-local identifiers are set
    /// for the duration of `body`, and `outcome` is evaluated before `.finish`
    /// is emitted.
    ///
    /// `metadata` is `@autoclosure`d for the same reason as the synchronous
    /// overload — when no recorder is installed, the dictionary expression is
    /// not evaluated.
    @MainActor
    package static func withSpan<T>(
        domain: InternalExecutionTraceDomain,
        operation: String,
        recorder: InternalExecutionTraceRecorder?,
        metadata: @autoclosure () -> [String: String] = [:],
        _ body: () async -> T,
        outcome: @escaping (T) -> String
    ) async -> T {
        guard let recorder else {
            return await body()
        }

        let rootID = currentRootID ?? UUID().uuidString
        let parentSpanID = currentSpanID
        let spanID = UUID().uuidString
        let context = InternalExecutionTraceContext(
            rootID: rootID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            domain: domain
        )

        recorder(.start(context: context, operation: operation, metadata: metadata()))
        return await $currentRootID.withValue(rootID) {
            await $currentSpanID.withValue(spanID) {
                let value = await body()
                recorder(.finish(context: context, operation: operation, outcome: outcome(value)))
                return value
            }
        }
    }

    /// Runs a throwing asynchronous body inside a traced span on the main actor.
    @MainActor
    package static func withSpan<T>(
        domain: InternalExecutionTraceDomain,
        operation: String,
        recorder: InternalExecutionTraceRecorder?,
        metadata: @autoclosure () -> [String: String] = [:],
        _ body: () async throws -> T,
        outcome: @escaping (T) -> String
    ) async rethrows -> T {
        guard let recorder else {
            return try await body()
        }

        let rootID = currentRootID ?? UUID().uuidString
        let parentSpanID = currentSpanID
        let spanID = UUID().uuidString
        let context = InternalExecutionTraceContext(
            rootID: rootID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            domain: domain
        )

        recorder(.start(context: context, operation: operation, metadata: metadata()))
        return try await $currentRootID.withValue(rootID) {
            try await $currentSpanID.withValue(spanID) {
                do {
                    let value = try await body()
                    recorder(.finish(context: context, operation: operation, outcome: outcome(value)))
                    return value
                } catch {
                    recorder(.finish(context: context, operation: operation, outcome: "threw"))
                    throw error
                }
            }
        }
    }
}
