// MARK: - FlowTestStore+TypedReceivers.swift
// InnoRouterTesting - case-specific navigation and modal event assertions.

import InnoRouterCore
import InnoRouterSwiftUI

extension FlowTestStore {
    public func receiveNavigationChanged(
        _ predicate: (RouteStack<R>, RouteStack<R>) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationChanged",
            expected: ".changed",
            extract: { event -> (from: RouteStack<R>, to: RouteStack<R>)? in
                guard case .changed(let from, let to) = event else { return nil }
                return (from, to)
            },
            check: { predicate($0.from, $0.to) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveNavigationBatch(
        _ predicate: (NavigationBatchResult<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationBatch",
            expected: ".batchExecuted",
            extract: { event -> NavigationBatchResult<R>? in
                guard case .batchExecuted(let result) = event else { return nil }
                return result
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveNavigationTransaction(
        _ predicate: (NavigationTransactionResult<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationTransaction",
            expected: ".transactionExecuted",
            extract: { event -> NavigationTransactionResult<R>? in
                guard case .transactionExecuted(let result) = event else { return nil }
                return result
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveNavigationMiddlewareMutation(
        _ predicate: (MiddlewareMutationEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationMiddlewareMutation",
            expected: ".middlewareMutation",
            extract: { event -> MiddlewareMutationEvent<R>? in
                guard case .middlewareMutation(let mutation) = event else { return nil }
                return mutation
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveNavigationPathMismatch(
        _ predicate: (NavigationPathMismatchEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationPathMismatch",
            expected: ".pathMismatch",
            extract: { event -> NavigationPathMismatchEvent<R>? in
                guard case .pathMismatch(let mismatch) = event else { return nil }
                return mismatch
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveModalPresented(
        _ predicate: (ModalPresentation<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalPresented",
            expected: ".presented",
            extract: { event -> ModalPresentation<R>? in
                guard case .presented(let presentation) = event else { return nil }
                return presentation
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveModalDismissed(
        _ predicate: (ModalPresentation<R>, ModalDismissalReason) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalDismissed",
            expected: ".dismissed",
            extract: { event -> (presentation: ModalPresentation<R>, reason: ModalDismissalReason)? in
                guard case .dismissed(let presentation, let reason) = event else { return nil }
                return (presentation, reason)
            },
            check: { predicate($0.presentation, $0.reason) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveModalQueueChanged(
        _ predicate: ([ModalPresentation<R>], [ModalPresentation<R>]) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalQueueChanged",
            expected: ".queueChanged",
            extract: { event -> (old: [ModalPresentation<R>], new: [ModalPresentation<R>])? in
                guard case .queueChanged(let old, let new) = event else { return nil }
                return (old, new)
            },
            check: { predicate($0.old, $0.new) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveModalCommandIntercepted(
        _ predicate: (ModalCommand<R>, ModalExecutionResult<R>) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalCommandIntercepted",
            expected: ".commandIntercepted",
            extract: { event -> (command: ModalCommand<R>, result: ModalExecutionResult<R>)? in
                guard case .commandIntercepted(let command, let result) = event else { return nil }
                return (command, result)
            },
            check: { predicate($0.command, $0.result) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    public func receiveModalMiddlewareMutation(
        _ predicate: (ModalMiddlewareMutationEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalMiddlewareMutation",
            expected: ".middlewareMutation",
            extract: { event -> ModalMiddlewareMutationEvent<R>? in
                guard case .middlewareMutation(let mutation) = event else { return nil }
                return mutation
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    private func receiveNavigationCase<Payload>(
        label: String,
        expected: String,
        extract: (NavigationEvent<R>) -> Payload?,
        check: (Payload) -> Bool,
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — queue is empty (expected .navigation(\(expected))).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .navigation(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected .navigation(\(expected)), got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard let payload = extract(event) else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected \(expected), got \(Self.navigationCaseName(event)) — \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !check(payload) {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — payload predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    private func receiveModalCase<Payload>(
        label: String,
        expected: String,
        extract: (ModalEvent<R>) -> Payload?,
        check: (Payload) -> Bool,
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — queue is empty (expected .modal(\(expected))).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .modal(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected .modal(\(expected)), got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard let payload = extract(event) else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected \(expected), got \(Self.modalCaseName(event)) — \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !check(payload) {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — payload predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    private static func navigationCaseName(_ event: NavigationEvent<R>) -> String {
        switch event {
        case .changed: return ".changed"
        case .batchExecuted: return ".batchExecuted"
        case .transactionExecuted: return ".transactionExecuted"
        case .middlewareMutation: return ".middlewareMutation"
        case .pathMismatch: return ".pathMismatch"
        }
    }

    private static func modalCaseName(_ event: ModalEvent<R>) -> String {
        switch event {
        case .presented: return ".presented"
        case .dismissed: return ".dismissed"
        case .replaced: return ".replaced"
        case .queueChanged: return ".queueChanged"
        case .commandIntercepted: return ".commandIntercepted"
        case .middlewareMutation: return ".middlewareMutation"
        }
    }
}
