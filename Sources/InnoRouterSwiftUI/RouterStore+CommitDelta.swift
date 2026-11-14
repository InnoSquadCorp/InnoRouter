// MARK: - RouterStore+CommitDelta.swift
// InnoRouterSwiftUI - what one commit changed, computed once
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterStore {
    /// Returns the application-domain paths whose subtree differs between two
    /// states that have the same scopes and presentations, or `nil` when the
    /// two states are not that similar.
    ///
    /// Most commits change a value inside one scope (a stack path, a badge, a
    /// selection) and leave the shape of the graph alone. Runtime lifetimes
    /// are a function of that shape only, and a scope's projection is a
    /// function of its own subtree, so for such a commit the lifetime maps are
    /// already correct and only the scopes on a returned path can have
    /// anything to publish. Rebuilding the maps and re-deriving every scope
    /// regardless was the dominant per-commit cost on wide trees.
    ///
    /// `nil` covers every case this shortcut must not reason about: a scope
    /// or presentation that appeared, disappeared, or changed identity or
    /// kind, and any change to windows or the immersive space. The caller
    /// then takes the general path.
    ///
    /// A subtree that compares equal is never entered, so the cost is one
    /// value comparison per sibling on the way down to what changed.
    static func subtreesChanged(
        from before: RouterState<R>,
        to after: RouterState<R>
    ) -> Set<RouterScopePath>? {
        guard before.windows == after.windows,
              before.immersiveSpace == after.immersiveSpace else { return nil }
        var changed: Set<RouterScopePath> = []
        guard before.root != after.root else { return changed }
        // Every entry is a pair already known to differ.
        var pending: [(path: RouterScopePath, old: RouterNode<R>, new: RouterNode<R>)] = [
            (.root, before.root, after.root),
        ]
        while let entry = pending.popLast() {
            changed.insert(entry.path)
            switch (entry.old, entry.new) {
            case (.stack(let old), .stack(let new)):
                switch (old.presentationFamily, new.presentationFamily) {
                case (nil, nil):
                    break
                case (.navigation(let oldChild)?, .navigation(let newChild)?):
                    guard oldChild.id == newChild.id else { return nil }
                    if oldChild.node != newChild.node {
                        pending.append((
                            entry.path.appendingPresentation(oldChild.id), oldChild.node, newChild.node
                        ))
                    }
                case (let oldFamily?, let newFamily?):
                    guard oldFamily.id == newFamily.id, oldFamily.kind == newFamily.kind else { return nil }
                default:
                    return nil
                }
            case (.container(let old), .container(let new)):
                guard old.style == new.style, old.branches.count == new.branches.count else { return nil }
                for index in old.branches.indices {
                    let oldBranch = old.branches[index]
                    let newBranch = new.branches[index]
                    guard oldBranch.id == newBranch.id else { return nil }
                    if oldBranch.node != newBranch.node {
                        pending.append((entry.path.appending(oldBranch.id), oldBranch.node, newBranch.node))
                    }
                }
            default:
                return nil
            }
        }
        return changed
    }
}
