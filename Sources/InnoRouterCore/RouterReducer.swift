// MARK: - RouterReducer.swift
// InnoRouterCore - pure canonical state transitions
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Pure state transition engine used by the runtime and deterministic tests.
public enum RouterReducer {
    /// Returns the next state, or a typed error without mutating `state`.
    public static func reduce<R: Route>(
        _ action: RouterAction<R>,
        from state: RouterState<R>
    ) throws -> RouterState<R> {
        var next = state
        do {
            try apply(action, to: &next, path: .root)
            try next.validate()
            try validatePresentationIdentityContinuity(from: state, to: next)
            try validateWindowIdentityContinuity(from: state, to: next)
        } catch let error as RouterStateValidationError {
            throw RouterMutationError.invalidTargetState(error)
        }
        return next
    }

    private static func apply<R: Route>(
        _ action: RouterAction<R>,
        to state: inout RouterState<R>,
        path: RouterScopePath
    ) throws {
        switch action {
        case .windowScoped, .immersiveSpaceScoped, .openWindow, .dismissWindow,
             .enterImmersiveSpace, .dismissImmersiveSpace, .apply:
            try applyGlobalAction(action, to: &state, path: path)
        default:
            try apply(action, to: &state.root, path: path)
        }
    }

    private static func applyGlobalAction<R: Route>(
        _ action: RouterAction<R>,
        to state: inout RouterState<R>,
        path: RouterScopePath
    ) throws {
        guard path == .root else { throw RouterMutationError.scopedGlobalAction(path) }
        switch action {
        case .windowScoped(let id, let childAction):
            guard let index = state.windows.firstIndex(where: { $0.id == id }) else {
                throw RouterMutationError.windowNotFound(id)
            }
            try apply(childAction, to: &state.windows[index].node, path: .window(id))
        case .immersiveSpaceScoped(let id, let childAction):
            guard var immersiveSpace = state.immersiveSpace,
                  immersiveSpace.id == id else {
                throw RouterMutationError.immersiveSpaceNotFound(id)
            }
            try apply(childAction, to: &immersiveSpace.node, path: .immersiveSpace(id))
            state.immersiveSpace = immersiveSpace
        case .openWindow(let window):
            state.windows.append(window)
        case .dismissWindow(let id):
            guard let index = state.windows.firstIndex(where: { $0.id == id }) else {
                throw RouterMutationError.windowNotFound(id)
            }
            state.windows.remove(at: index)
        case .enterImmersiveSpace(let space):
            state.immersiveSpace = space
        case .dismissImmersiveSpace:
            state.immersiveSpace = nil
        case .apply(let plan):
            state = plan.state
        default:
            preconditionFailure("expected a global action")
        }
    }

    private static func apply<R: Route>(
        _ action: RouterAction<R>,
        to node: inout RouterNode<R>,
        path: RouterScopePath
    ) throws {
        if case .scoped(let scope, let childAction) = action {
            guard case .container(var container) = node else {
                throw RouterMutationError.expectedContainer(path)
            }
            guard let index = container.branches.firstIndex(where: { $0.id == scope }) else {
                throw RouterMutationError.missingScope(scope, parent: path)
            }
            let childPath = path.appending(scope)
            try apply(childAction, to: &container.branches[index].node, path: childPath)
            node = .container(container)
            return
        }

        switch action {
        case .select, .setBadge, .clearAllBadges,
             .setSplitVisibility, .setPreferredCompactColumn:
            try applyContainerAction(action, to: &node, path: path)
        case .push, .pushIfNeeded, .backOrPush, .replaceTop,
             .pushMany, .pop, .popTo, .popToRoot, .replaceStack,
             .present, .dismissPresentation, .setPresentationDetent:
            try applyStackAction(action, to: &node, path: path)
        case .scoped:
            preconditionFailure("handled above")
        case .windowScoped, .immersiveSpaceScoped,
             .openWindow, .dismissWindow, .enterImmersiveSpace,
             .dismissImmersiveSpace, .apply:
            throw RouterMutationError.scopedGlobalAction(path)
        }
    }

    private static func applyContainerAction<R: Route>(
        _ action: RouterAction<R>,
        to node: inout RouterNode<R>,
        path: RouterScopePath
    ) throws {
        guard case .container(var container) = node else {
            throw RouterMutationError.expectedContainer(path)
        }

        switch action {
        case .select(let selection):
            guard container.branches.contains(where: { $0.id == selection }) else {
                throw RouterMutationError.missingScope(selection, parent: path)
            }
            container.selection = selection
        case .setBadge(let count, let scope):
            guard container.branches.contains(where: { $0.id == scope }) else {
                throw RouterMutationError.missingScope(scope, parent: path)
            }
            container.badges[scope] = count.flatMap { $0 > 0 ? $0 : nil }
        case .clearAllBadges:
            container.badges.removeAll(keepingCapacity: true)
        case .setSplitVisibility(let visibility):
            guard container.style == .split, var split = container.split else {
                throw RouterMutationError.expectedSplitContainer(path)
            }
            split.visibility = visibility
            container.split = split
        case .setPreferredCompactColumn(let column):
            guard container.style == .split, var split = container.split else {
                throw RouterMutationError.expectedSplitContainer(path)
            }
            guard split.scopeID(for: column) != nil else {
                throw RouterMutationError.unavailableSplitColumn(column, scope: path)
            }
            split.preferredCompactColumn = column
            container.split = split
        default:
            preconditionFailure("expected a container action")
        }

        node = .container(container)
    }

    private static func applyStackAction<R: Route>(
        _ action: RouterAction<R>,
        to node: inout RouterNode<R>,
        path: RouterScopePath
    ) throws {
        switch action {
        case .push(let route):
            try mutateStack(&node, at: path) { stack in
                try requireNoPresentation(stack, at: path)
                stack.path.append(route)
            }
        case .pushIfNeeded, .backOrPush, .replaceTop:
            try applyIdempotentStackAction(action, to: &node, path: path)
        case .pushMany(let routes):
            try mutateStack(&node, at: path) { stack in
                try requireNoPresentation(stack, at: path)
                stack.path.append(contentsOf: routes)
            }
        case .pop, .popTo, .popToRoot:
            try applyStackRemovalAction(action, to: &node, path: path)
        case .replaceStack(let routes):
            try mutateStack(&node, at: path) { stack in
                try requireNoPresentation(stack, at: path)
                stack.path = routes
            }
        case .present(let presentation):
            try mutateStack(&node, at: path) { stack in
                guard stack.presentation == nil else {
                    throw RouterMutationError.presentationAlreadyActive(path)
                }
                stack.presentation = presentation
            }
        case .dismissPresentation:
            try mutateStack(&node, at: path) { stack in
                stack.presentation = nil
            }
        case .setPresentationDetent(let detent):
            try mutateStack(&node, at: path) { stack in
                guard var presentation = stack.presentation else {
                    throw RouterMutationError.presentationNotActive(path)
                }
                guard presentation.options.detents.isEmpty
                    ? detent == .large
                    : presentation.options.detents.contains(detent) else {
                    throw RouterMutationError.unavailablePresentationDetent(detent, scope: path)
                }
                presentation.options.selectedDetent = detent
                stack.presentation = presentation
            }
        default:
            preconditionFailure("expected a stack action")
        }
    }

    private static func applyIdempotentStackAction<R: Route>(
        _ action: RouterAction<R>,
        to node: inout RouterNode<R>,
        path: RouterScopePath
    ) throws {
        try mutateStack(&node, at: path) { stack in
            try requireNoPresentation(stack, at: path)
            switch action {
            case .pushIfNeeded(let route):
                guard stack.path.last != route else { return }
                stack.path.append(route)
            case .backOrPush(let route):
                if let index = stack.path.lastIndex(of: route) {
                    stack.path.removeSubrange(stack.path.index(after: index)..<stack.path.endIndex)
                } else {
                    stack.path.append(route)
                }
            case .replaceTop(let route):
                if stack.path.isEmpty {
                    stack.path.append(route)
                } else {
                    stack.path[stack.path.index(before: stack.path.endIndex)] = route
                }
            default:
                preconditionFailure("expected an idempotent stack action")
            }
        }
    }

    private static func applyStackRemovalAction<R: Route>(
        _ action: RouterAction<R>,
        to node: inout RouterNode<R>,
        path: RouterScopePath
    ) throws {
        try mutateStack(&node, at: path) { stack in
            try requireNoPresentation(stack, at: path)
            switch action {
            case .pop(let count):
                guard count >= 0, count <= stack.path.count else {
                    throw RouterMutationError.invalidPopCount(
                        requested: count,
                        available: stack.path.count,
                        scope: path
                    )
                }
                stack.path.removeLast(count)
            case .popTo(let route):
                guard let index = stack.path.lastIndex(of: route) else { return }
                stack.path.removeSubrange(stack.path.index(after: index)..<stack.path.endIndex)
            case .popToRoot:
                stack.path.removeAll(keepingCapacity: true)
            default:
                preconditionFailure("expected a stack removal action")
            }
        }
    }

    private static func mutateStack<R: Route>(
        _ node: inout RouterNode<R>,
        at path: RouterScopePath,
        mutation: (inout RouterStackState<R>) throws -> Void
    ) throws {
        guard case .stack(var stack) = node else {
            throw RouterMutationError.expectedStack(path)
        }
        try mutation(&stack)
        node = .stack(stack)
    }

    private static func requireNoPresentation<R: Route>(
        _ stack: RouterStackState<R>,
        at path: RouterScopePath
    ) throws {
        guard stack.presentation == nil else {
            throw RouterMutationError.blockedByPresentation(path)
        }
    }

    private static func validatePresentationIdentityContinuity<R: Route>(
        from current: RouterState<R>,
        to proposed: RouterState<R>
    ) throws {
        let currentPresentations = locatedPresentations(in: current)
        let proposedPresentations = locatedPresentations(in: proposed)

        for (id, currentPresentation) in currentPresentations {
            guard let proposedPresentation = proposedPresentations[id] else { continue }
            guard currentPresentation.path == proposedPresentation.path,
                  presentationIdentityIsContinuous(
                      currentPresentation.presentation,
                      proposedPresentation.presentation
                  ) else {
                throw RouterMutationError.presentationIdentityConflict(id)
            }
        }
    }

    private static func presentationIdentityIsContinuous<R: Route>(
        _ current: RouterPresentation<R>,
        _ proposed: RouterPresentation<R>
    ) -> Bool {
        var currentOptions = current.options
        var proposedOptions = proposed.options
        currentOptions.selectedDetent = nil
        proposedOptions.selectedDetent = nil
        return current.route == proposed.route
            && current.style == proposed.style
            && currentOptions == proposedOptions
    }

    private static func locatedPresentations<R: Route>(
        in state: RouterState<R>
    ) -> [UUID: LocatedRouterPresentation<R>] {
        var result: [UUID: LocatedRouterPresentation<R>] = [:]

        func visit(_ node: RouterNode<R>, at path: RouterScopePath) {
            switch node {
            case .stack(let stack):
                if let presentation = stack.presentation {
                    result[presentation.id] = LocatedRouterPresentation(
                        path: path,
                        presentation: presentation
                    )
                }
            case .container(let container):
                for branch in container.branches {
                    visit(branch.node, at: path.appending(branch.id))
                }
            }
        }

        visit(state.root, at: .root)
        for window in state.windows {
            visit(window.node, at: .window(window.id))
        }
        if let immersiveSpace = state.immersiveSpace {
            visit(
                immersiveSpace.node,
                at: .immersiveSpace(immersiveSpace.id)
            )
        }
        return result
    }

    private static func validateWindowIdentityContinuity<R: Route>(
        from current: RouterState<R>,
        to proposed: RouterState<R>
    ) throws {
        let currentByID = Dictionary(
            uniqueKeysWithValues: current.windows.map { ($0.id, $0.route) }
        )
        for window in proposed.windows {
            guard let currentRoute = currentByID[window.id] else { continue }
            guard currentRoute == window.route else {
                throw RouterMutationError.windowIdentityConflict(window.id)
            }
        }
    }
}

private struct LocatedRouterPresentation<R: Route> {
    let path: RouterScopePath
    let presentation: RouterPresentation<R>
}
