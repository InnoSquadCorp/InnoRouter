// MARK: - FlowTestStore+Receivers.swift
// InnoRouterTesting - general flow event assertions.

import InnoRouterCore
import InnoRouterSwiftUI

extension FlowTestStore {
    public func receive(
        _ expected: FlowEvent<R>,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receive(\(expected)) — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if actual != expected {
            recordTestStoreIssue(
                """
                FlowTestStore.receive mismatch.
                Expected: \(expected)
                Actual:   \(actual)
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receivePathChanged(
        _ predicate: ([RouteStep<R>], [RouteStep<R>]) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receivePathChanged — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .pathChanged(let old, let new) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receivePathChanged — expected .pathChanged, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(old, new) {
            recordTestStoreIssue(
                "FlowTestStore.receivePathChanged predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receiveIntentRejected(
        intent: FlowIntent<R>,
        reason: FlowRejectionReason,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receiveIntentRejected — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .intentRejected(let observedIntent, let observedReason) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receiveIntentRejected — expected .intentRejected, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if observedIntent != intent || observedReason != reason {
            recordTestStoreIssue(
                """
                FlowTestStore.receiveIntentRejected mismatch.
                Expected: (\(intent), \(reason))
                Actual:   (\(observedIntent), \(observedReason))
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receiveNavigation(
        _ predicate: (NavigationEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receiveNavigation — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .navigation(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receiveNavigation — expected .navigation, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(event) {
            recordTestStoreIssue(
                "FlowTestStore.receiveNavigation predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receiveModal(
        _ predicate: (ModalEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receiveModal — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .modal(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receiveModal — expected .modal, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(event) {
            recordTestStoreIssue(
                "FlowTestStore.receiveModal predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }
}
