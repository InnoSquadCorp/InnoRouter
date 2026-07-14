// MARK: - TestEventQueue.swift
// InnoRouterTesting - FIFO event queue shared by all test stores
// Copyright © 2026 Inno Squad. All rights reserved.

/// A FIFO queue of events observed by a test store.
///
/// Used internally by `NavigationTestStore`, `ModalTestStore`, and
/// `FlowTestStore` to buffer events produced by their underlying authority
/// between `send(...)` and `receive(...)` calls. All test stores are
/// `@MainActor`-isolated, so the queue does not require an internal lock —
/// the actor isolation itself serialises access.
@MainActor
final class TestEventQueue<Event> {
    private struct FinishContext {
        let fileID: String
        let filePath: String
        let line: Int
        let column: Int
        let reportsLateEvents: Bool
    }

    private let storeName: String
    private let exhaustivity: TestExhaustivity
    private var events: [Event] = []
    private var finishContext: FinishContext?
    private var didReportLateEvent = false

    init(storeName: String, exhaustivity: TestExhaustivity) {
        self.storeName = storeName
        self.exhaustivity = exhaustivity
    }

    /// Appends an event to the tail of the queue.
    func enqueue(_ event: Event) {
        if let finishContext {
            guard finishContext.reportsLateEvents, !didReportLateEvent else { return }
            didReportLateEvent = true
            recordTestStoreIssue(
                """
                \(storeName) received an event after finish():
                  - \(event)
                Additional events after finish() are discarded.
                """,
                fileID: finishContext.fileID,
                filePath: finishContext.filePath,
                line: finishContext.line,
                column: finishContext.column
            )
            return
        }
        events.append(event)
    }

    /// Dequeues and returns the head of the queue, or `nil` if empty.
    func dequeue() -> Event? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    /// A snapshot of all events currently buffered, in FIFO order.
    var remaining: [Event] {
        events
    }

    /// Drops every buffered event without firing any assertions.
    func drain() {
        events.removeAll()
    }

    /// Checks and consumes the queue without ending the test-store lifecycle.
    func assertNoPendingEvents(
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        guard !events.isEmpty else { return }
        let pending = events
        events.removeAll()
        recordTestStoreIssue(
            """
            \(storeName) has \(pending.count) unasserted event(s):
            \(pending.map { "  - \($0)" }.joined(separator: "\n"))
            """,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Ends observation and reports any queued events according to exhaustivity.
    func finish(
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        complete(
            completionDescription: "finished",
            reportsLateEvents: true,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Performs the fallback check while preventing escaped stores from queuing
    /// events after their test-store wrapper has deallocated.
    func finishAtDeinitialization(
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        complete(
            completionDescription: "deallocated",
            reportsLateEvents: false,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    private func complete(
        completionDescription: String,
        reportsLateEvents: Bool,
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        guard finishContext == nil else { return }
        finishContext = FinishContext(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            reportsLateEvents: reportsLateEvents
        )

        let pending = events
        events.removeAll()
        guard exhaustivity == .strict, !pending.isEmpty else { return }
        recordTestStoreIssue(
            """
            \(storeName) \(completionDescription) with \(pending.count) unasserted event(s):
            \(pending.map { "  - \($0)" }.joined(separator: "\n"))
            """,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}
