// MARK: - RouterState+ReplacingNode.swift
// InnoRouterCore - exact subtree value replacement
// Copyright © 2026 Inno Squad. All rights reserved.

public extension RouterState {
    /// Returns a copy whose exact subtree at `path` is replaced.
    ///
    /// Feature-route composition uses this value operation to merge a child
    /// plan while preserving every unrelated sibling and application scene.
    func replacingNode(
        _ replacement: RouterNode<R>,
        at path: RouterScopePath
    ) throws -> RouterState<R> {
        var result = self
        switch path.domain {
        case .application:
            try Self.replaceNode(
                node: &result.root,
                components: ArraySlice(path.components),
                replacement: replacement,
                parentPath: .root
            )
        case .window(let id):
            guard let index = result.windows.firstIndex(where: { $0.id == id }) else {
                throw RouterMutationError.windowNotFound(id)
            }
            try Self.replaceNode(
                node: &result.windows[index].node,
                components: ArraySlice(path.components),
                replacement: replacement,
                parentPath: .window(id)
            )
        case .immersiveSpace(let id):
            guard var space = result.immersiveSpace, space.id == id else {
                throw RouterMutationError.immersiveSpaceNotFound(id)
            }
            try Self.replaceNode(
                node: &space.node,
                components: ArraySlice(path.components),
                replacement: replacement,
                parentPath: .immersiveSpace(id)
            )
            result.immersiveSpace = space
        }
        try result.validate()
        return result
    }

    private static func replaceNode(
        node: inout RouterNode<R>,
        components: ArraySlice<RouterScopeComponent>,
        replacement: RouterNode<R>,
        parentPath: RouterScopePath
    ) throws {
        guard let first = components.first else {
            node = replacement
            return
        }
        switch first {
        case .branch(let id):
            guard case .container(var container) = node else {
                throw RouterMutationError.expectedContainer(parentPath)
            }
            guard let index = container.branches.firstIndex(where: { $0.id == id }) else {
                throw RouterMutationError.missingScope(id, parent: parentPath)
            }
            try replaceNode(
                node: &container.branches[index].node,
                components: components.dropFirst(),
                replacement: replacement,
                parentPath: parentPath.appending(id)
            )
            node = .container(container)
        case .presentation(let id):
            guard case .stack(var stack) = node else {
                throw RouterMutationError.expectedStack(parentPath)
            }
            guard var presentation = stack.presentation, presentation.id == id else {
                throw RouterMutationError.presentationIdentityMismatch(
                    scope: parentPath, expected: id, actual: stack.presentation?.id
                )
            }
            try replaceNode(
                node: &presentation.node,
                components: components.dropFirst(),
                replacement: replacement,
                parentPath: parentPath.appendingPresentation(id)
            )
            stack.presentation = presentation
            node = .stack(stack)
        }
    }
}
