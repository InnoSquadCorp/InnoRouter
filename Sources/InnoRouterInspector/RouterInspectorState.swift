import Foundation
import Observation

import InnoRouterCore

/// Payload-redacted structural kind rendered by the inspector.
public enum RouterInspectorNodeKind: String, Sendable, Codable {
    case stack
    case tabs
    case split
    case custom
    case window
    case immersiveSpace
}

/// One payload-redacted node in a captured router state tree.
public struct RouterInspectorStateNode: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let label: String
    public let kind: RouterInspectorNodeKind
    public let details: [String: String]
    public let children: [RouterInspectorStateNode]

    public init(
        id: String,
        label: String,
        kind: RouterInspectorNodeKind,
        details: [String: String] = [:],
        children: [RouterInspectorStateNode] = []
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.details = details
        self.children = children
    }
}

/// A complete structural state capture with route payloads removed.
public struct RouterInspectorStateTree: Sendable, Equatable, Codable {
    public let root: RouterInspectorStateNode
    public let windows: [RouterInspectorStateNode]
    public let immersiveSpace: RouterInspectorStateNode?

    public init(
        root: RouterInspectorStateNode,
        windows: [RouterInspectorStateNode] = [],
        immersiveSpace: RouterInspectorStateNode? = nil
    ) {
        self.root = root
        self.windows = windows
        self.immersiveSpace = immersiveSpace
    }

    public var flattenedNodes: [RouterInspectorFlatNode] {
        var result: [RouterInspectorFlatNode] = []
        func append(_ node: RouterInspectorStateNode, depth: Int) {
            result.append(.init(node: node, depth: depth))
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }
        append(root, depth: 0)
        for window in windows { append(window, depth: 0) }
        if let immersiveSpace { append(immersiveSpace, depth: 0) }
        return result
    }
}

/// A flattened tree row convenient for native List and outline rendering.
public struct RouterInspectorFlatNode: Sendable, Equatable, Identifiable {
    public let node: RouterInspectorStateNode
    public let depth: Int

    public var id: String { node.id }
}

/// One structural field changed by a committed transition.
public struct RouterInspectorStateChange: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let path: String
    public let field: String
    public let before: String
    public let after: String

    public init(path: String, field: String, before: String, after: String) {
        self.id = "\(path)#\(field)"
        self.path = path
        self.field = field
        self.before = before
        self.after = after
    }
}

/// Payload-redacted field diff between two exact router states.
public struct RouterInspectorStateDiff: Sendable, Equatable, Codable {
    public let changes: [RouterInspectorStateChange]

    public init(changes: [RouterInspectorStateChange]) {
        self.changes = changes
    }
}

/// Result of executing an action with the pure reducer in isolation.
public struct RouterInspectorReplayPreview: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case matchedProposal
        case proposalMismatch
        case rejected
    }

    public let status: Status
    public let state: RouterInspectorStateTree?
    public let error: String?

    public init(status: Status, state: RouterInspectorStateTree?, error: String? = nil) {
        self.status = status
        self.state = state
        self.error = error
    }
}

/// Safe inspector algorithms. Replay is pure and can never mutate a live store.
public enum RouterInspectorReplay {
    public static func preview<R: Route>(
        _ transition: RouterTransition<R>
    ) -> RouterInspectorReplayPreview {
        do {
            let state = try RouterReducer.reduce(
                transition.action,
                from: transition.initialState
            )
            return .init(
                status: state == transition.proposedState
                    ? .matchedProposal
                    : .proposalMismatch,
                state: RouterInspectorProjection.tree(from: state)
            )
        } catch {
            return .init(
                status: .rejected,
                state: nil,
                error: String(describing: type(of: error))
            )
        }
    }
}

/// Payload-redacted state projection and diff helpers.
public enum RouterInspectorProjection {
    public static func tree<R: Route>(from state: RouterState<R>) -> RouterInspectorStateTree {
        .init(
            root: node(state.root, path: .root, label: "root"),
            windows: state.windows.indices.map { index in
                .init(
                    id: "window[\(index)]",
                    label: "window \(index + 1)",
                    kind: .window,
                    children: [
                        node(
                            state.windows[index].node,
                            path: .scene(kind: "window", index: index),
                            label: "content"
                        )
                    ]
                )
            },
            immersiveSpace: state.immersiveSpace.map { space in
                .init(
                    id: "immersive",
                    label: "immersive space",
                    kind: .immersiveSpace,
                    children: [
                        node(
                            space.node,
                            path: .scene(kind: "immersive", index: 0),
                            label: "content"
                        )
                    ]
                )
            }
        )
    }

    public static func diff<R: Route>(
        from before: RouterState<R>,
        to after: RouterState<R>
    ) -> RouterInspectorStateDiff {
        let beforeTree = tree(from: before)
        let afterTree = tree(from: after)
        let lhs = summaries(in: beforeTree)
        let rhs = summaries(in: afterTree)
        let keys = Set(lhs.keys).union(rhs.keys).sorted()
        var changes: [RouterInspectorStateChange] = []
        for key in keys {
            let old = lhs[key] ?? [:]
            let new = rhs[key] ?? [:]
            for field in Set(old.keys).union(new.keys).sorted() where old[field] != new[field] {
                changes.append(
                    .init(
                        path: key,
                        field: field,
                        before: old[field] ?? "absent",
                        after: new[field] ?? "absent"
                    )
                )
            }
        }
        return .init(changes: changes)
    }

    /// Compares two imported, already-redacted state trees.
    public static func diff(
        from before: RouterInspectorStateTree,
        to after: RouterInspectorStateTree
    ) -> RouterInspectorStateDiff {
        let lhs = summaries(in: before)
        let rhs = summaries(in: after)
        let keys = Set(lhs.keys).union(rhs.keys).sorted()
        var changes: [RouterInspectorStateChange] = []
        for key in keys {
            let old = lhs[key] ?? [:]
            let new = rhs[key] ?? [:]
            for field in Set(old.keys).union(new.keys).sorted() where old[field] != new[field] {
                changes.append(
                    .init(
                        path: key,
                        field: field,
                        before: old[field] ?? "absent",
                        after: new[field] ?? "absent"
                    )
                )
            }
        }
        return .init(changes: changes)
    }

    private static func node<R: Route>(
        _ value: RouterNode<R>,
        path: RedactedScopePath,
        label: String
    ) -> RouterInspectorStateNode {
        switch value {
        case .stack(let stack):
            var details = ["routes": "\(stack.path.count)"]
            details["presentation"] = stack.presentation?.style.rawValue ?? "none"
            return .init(
                id: path.description,
                label: label,
                kind: .stack,
                details: details
            )
        case .container(let container):
            let kind: RouterInspectorNodeKind
            switch container.style {
            case .tabs: kind = .tabs
            case .split: kind = .split
            case .custom: kind = .custom
            }
            let details = [
                "selection": container.selection.flatMap { selection in
                    container.branches.firstIndex(where: { $0.id == selection })
                }.map { "branch[\($0)]" } ?? "none",
                "badges": "\(container.badges.count)",
                "splitVisibility": container.split?.visibility.rawValue ?? "none",
                "preferredCompactColumn": container.split?.preferredCompactColumn.rawValue
                    ?? "none",
            ]
            return .init(
                id: path.description,
                label: label,
                kind: kind,
                details: details,
                children: container.branches.enumerated().map { index, branch in
                    node(
                        branch.node,
                        path: path.appending(index),
                        label: "branch \(index + 1)"
                    )
                }
            )
        }
    }

    private struct RedactedScopePath: CustomStringConvertible {
        static let root = RedactedScopePath(prefix: "", components: [])

        let prefix: String
        let components: [Int]

        static func scene(kind: String, index: Int) -> Self {
            .init(prefix: "/\(kind)[\(index)]", components: [])
        }

        func appending(_ index: Int) -> Self {
            .init(prefix: prefix, components: components + [index])
        }

        var description: String {
            guard !components.isEmpty else { return prefix.isEmpty ? "/" : prefix }
            return prefix + "/" + components.map { "branch[\($0)]" }.joined(separator: "/")
        }
    }

    private static func summaries(
        in tree: RouterInspectorStateTree
    ) -> [String: [String: String]] {
        var values: [String: [String: String]] = [:]
        for row in tree.flattenedNodes {
            values[row.node.id] = row.node.details.merging(
                ["kind": row.node.kind.rawValue],
                uniquingKeysWith: { _, new in new }
            )
        }
        values["$application"] = [
            "windows": "\(tree.windows.count)",
            "immersive": tree.immersiveSpace == nil ? "0" : "1",
        ]
        return values
    }
}

/// Comparison helpers for exported inspector sessions.
public enum RouterInspectorComparison {
    /// Compares the final captured state in each snapshot.
    public static func finalStates(
        in before: RouterInspectorSnapshot,
        and after: RouterInspectorSnapshot
    ) -> RouterInspectorStateDiff? {
        guard let lhs = before.entries.reversed().compactMap(\.state).first,
              let rhs = after.entries.reversed().compactMap(\.state).first else {
            return nil
        }
        return RouterInspectorProjection.diff(from: lhs, to: rhs)
    }

    /// Compares captured states at any two entry identities in one snapshot.
    public static func states(
        at beforeID: RouterInspectorEntry.ID,
        and afterID: RouterInspectorEntry.ID,
        in snapshot: RouterInspectorSnapshot
    ) -> RouterInspectorStateDiff? {
        guard let before = snapshot.entries.first(where: { $0.id == beforeID })?.state,
              let after = snapshot.entries.first(where: { $0.id == afterID })?.state else {
            return nil
        }
        return RouterInspectorProjection.diff(from: before, to: after)
    }
}

/// Pure, non-mutating cursor over an exported inspector session.
@MainActor
@Observable
public final class RouterInspectorPlayback {
    public private(set) var snapshot: RouterInspectorSnapshot
    public private(set) var position: Int?
    public private(set) var comparisonEntryID: RouterInspectorEntry.ID?

    public init(
        snapshot: RouterInspectorSnapshot,
        startsAtEnd: Bool = false
    ) {
        self.snapshot = snapshot
        if snapshot.entries.isEmpty {
            self.position = nil
        } else {
            self.position = startsAtEnd ? snapshot.entries.index(before: snapshot.entries.endIndex) : 0
        }
    }

    public var currentEntry: RouterInspectorEntry? {
        guard let position, snapshot.entries.indices.contains(position) else { return nil }
        return snapshot.entries[position]
    }

    public var canStepBackward: Bool {
        guard let position else { return false }
        return position > snapshot.entries.startIndex
    }

    public var canStepForward: Bool {
        guard let position else { return false }
        return position < snapshot.entries.index(before: snapshot.entries.endIndex)
    }

    /// Structural comparison with the nearest earlier captured state.
    public var comparisonToPreviousState: RouterInspectorStateDiff? {
        guard let position,
              let current = snapshot.entries[position].state,
              position > snapshot.entries.startIndex else {
            return nil
        }
        for index in snapshot.entries.indices[..<position].reversed() {
            if let previous = snapshot.entries[index].state {
                return RouterInspectorProjection.diff(from: previous, to: current)
            }
        }
        return nil
    }

    public var comparisonToSelectedState: RouterInspectorStateDiff? {
        guard let comparisonEntryID, let currentEntry else { return nil }
        return RouterInspectorComparison.states(
            at: comparisonEntryID,
            and: currentEntry.id,
            in: snapshot
        )
    }

    public func setComparisonEntry(_ entryID: RouterInspectorEntry.ID?) {
        guard let entryID else {
            comparisonEntryID = nil
            return
        }
        comparisonEntryID = snapshot.entries.contains { $0.id == entryID }
            ? entryID
            : nil
    }

    public func stepBackward() {
        guard canStepBackward, let position else { return }
        self.position = snapshot.entries.index(before: position)
    }

    public func stepForward() {
        guard canStepForward, let position else { return }
        self.position = snapshot.entries.index(after: position)
    }

    public func jump(to entryID: RouterInspectorEntry.ID) {
        position = snapshot.entries.firstIndex { $0.id == entryID }
    }
}
