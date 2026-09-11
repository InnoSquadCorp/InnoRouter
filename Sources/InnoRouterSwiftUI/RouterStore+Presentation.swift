// MARK: - RouterStore+Presentation.swift
// InnoRouterSwiftUI - typed presentation lifecycle
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

@MainActor
public extension RouterStore {
    /// Presents a route at `path` and awaits its result-bearing lifecycle.
    func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle = .sheet,
        options: RouterPresentationOptions = .init(),
        at path: RouterScopePath = .root,
        expecting: Value.Type = Value.self
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            route,
            style: style,
            options: options,
            at: path,
            expecting: expecting,
            executionPrecondition: nil
        )
    }

    package func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        at path: RouterScopePath,
        expecting: Value.Type,
        executionPrecondition: RouterRequestPrecondition<R>?,
        requestSemantics: RouterRequestSemantics<R> = .action
    ) async -> RouterPresentationOutcome<Value> {
        let presentation = RouterPresentation(
            route: route,
            style: style,
            options: options
        )
        let waiter = RouterPresentationWaiter<Value>()
        presentationWaiters[presentation.id] = AnyRouterPresentationWaiter(
            prepareValue: { value, owner in
                guard let value = value as? Value else { return .typeMismatch }
                return waiter.prepare(value, owner: owner)
            },
            movePreparedValue: { currentOwner, nextOwner in
                waiter.movePreparedValue(from: currentOwner, to: nextOwner)
            },
            clearPreparedValue: { owner in
                waiter.clearPreparedValue(ownedBy: owner)
            },
            finishAfterDismissal: { owner in
                waiter.finishAfterDismissal(ownedBy: owner)
            },
            finishCancelled: { waiter.finish(.cancelled) },
            finishRejected: { waiter.finish(.rejected($0)) }
        )
        let presentationIsPending: RouterRequestPrecondition<R> = { [weak self] state in
            guard let self,
                  self.presentationWaiters[presentation.id] != nil else {
                return .cancelled
            }
            return executionPrecondition?(state)
        }
        let transitionID = reserveTransitionID()
        registerPresentationRequest(presentation.id, transitionID: transitionID)

        return await withTaskCancellationHandler {
            let outcome = await perform(
                RouterAction.present(presentation).inScope(path),
                context: .init(),
                expectedRevision: nil,
                bypassesPolicies: false,
                transitionID: transitionID,
                requestSemantics: requestSemantics,
                executionPrecondition: presentationIsPending
            )
            unregisterPresentationRequest(presentation.id, transitionID: transitionID)
            switch outcome {
            case .applied:
                break
            case .unchanged:
                presentationWaiters.removeValue(forKey: presentation.id)
                waiter.finish(.dismissed)
            case .deferred:
                break
            case .rejected(_, _, _, let reason):
                presentationWaiters.removeValue(forKey: presentation.id)
                if reason == .cancelled, Task.isCancelled {
                    waiter.finish(.cancelled)
                } else {
                    waiter.finish(.rejected(reason))
                }
            }
            return await waiter.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelPresentation(
                    id: presentation.id,
                    at: path
                )
            }
        }
    }

    /// Presents a macro-generated, result-typed request.
    func present<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        at path: RouterScopePath = .root
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            request.route,
            style: request.style,
            options: request.options,
            at: path,
            expecting: Value.self
        )
    }

    /// Supplies a value for the exact active presentation and dismisses it
    /// through the same policy pipeline. The awaiting caller resumes only
    /// after the dismissal commits.
    func finishPresentation<Value: Sendable>(
        at path: RouterScopePath = .root,
        returning value: Value
    ) async throws {
        try await finishPresentation(
            at: path,
            returning: value,
            executionPrecondition: nil
        )
    }

    package func finishPresentation<Value: Sendable>(
        at path: RouterScopePath,
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?,
        requestSemantics: RouterRequestSemantics<R> = .action
    ) async throws {
        guard let presentationID = presentationID(at: path) else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        guard let erasedWaiter = presentationWaiters[presentationID] else {
            throw RouterPresentationCompletionError.presentationWasNotAwaited(presentationID)
        }
        let transitionID = reserveTransitionID()
        let owner = RouterPresentationCompletionOwner.transition(transitionID)
        switch erasedWaiter.prepareValue(value, owner) {
        case .prepared:
            break
        case .typeMismatch:
            throw RouterPresentationCompletionError.resultTypeMismatch(presentationID)
        case .alreadyPending:
            throw RouterPresentationCompletionError.completionAlreadyPending(presentationID)
        }

        let outcome = await perform(
            RouterAction.dismissPresentation.inScope(path),
            context: .init(),
            expectedRevision: nil,
            bypassesPolicies: false,
            transitionID: transitionID,
            requestSemantics: requestSemantics,
            executionPrecondition: Self.combinePresentationPreconditions(
                Self.presentationIdentityPrecondition(id: presentationID, at: path),
                executionPrecondition
            )
        )
        if case .deferred(_, _, _, let deferral) = outcome {
            throw RouterPresentationCompletionError.dismissalDeferred(deferral.id)
        }
        if case .rejected(_, _, _, let reason) = outcome {
            erasedWaiter.clearPreparedValue(owner)
            throw RouterPresentationCompletionError.dismissalRejected(reason)
        }
        if case .unchanged = outcome {
            erasedWaiter.clearPreparedValue(owner)
            throw RouterPresentationCompletionError.dismissalRejected(
                .mutation(.presentationIdentityMismatch(
                    scope: path,
                    expected: presentationID,
                    actual: Self.presentationID(in: state, at: path)
                ))
            )
        }
    }

    /// Supplies the typed request's value only to the matching active route.
    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        at path: RouterScopePath = .root,
        returning value: Value
    ) async throws {
        try await finishPresentation(
            request,
            at: path,
            returning: value,
            executionPrecondition: nil
        )
    }

    package func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        at path: RouterScopePath,
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?,
        requestSemantics: RouterRequestSemantics<R> = .action
    ) async throws {
        guard case .stack(let stack) = state.node(at: path),
              let presentation = stack.presentation else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        guard presentation.route == request.route else {
            throw RouterPresentationCompletionError.presentationRouteMismatch(presentation.id)
        }
        try await finishPresentation(
            at: path,
            returning: value,
            executionPrecondition: executionPrecondition,
            requestSemantics: requestSemantics
        )
    }
}

@MainActor
extension RouterStore {
    func finishDeferredPresentation(
        for action: RouterAction<R>,
        owner: RouterPresentationCompletionOwner?,
        reason: RouterRejectionReason
    ) {
        guard let target = deferredPresentationTarget(in: action) else { return }
        switch target {
        case .present(let id):
            let waiter = presentationWaiters.removeValue(forKey: id)
            reason == .cancelled
                ? waiter?.finishCancelled()
                : waiter?.finishRejected(reason)
        case .dismiss(let path):
            guard let owner,
                  let id = presentationID(at: path) else { return }
            presentationWaiters[id]?.clearPreparedValue(owner)
        }
    }

    func continueDeferredPresentationCompletion(
        for action: RouterAction<R>,
        transitionID: RouterTransitionID,
        context: RouterTransitionContext,
        deferralID: RouterDeferralID
    ) {
        guard case .dismiss(let path) = deferredPresentationTarget(in: action),
              let presentationID = presentationID(at: path),
              let waiter = presentationWaiters[presentationID] else { return }
        let currentOwner = context.resumedDeferral.map {
            RouterPresentationCompletionOwner.deferral($0)
        } ?? .transition(transitionID)
        waiter.movePreparedValue(currentOwner, .deferral(deferralID))
    }

    func finishDismissedPresentations(
        before: RouterState<R>,
        after: RouterState<R>,
        transitionID: RouterTransitionID,
        context: RouterTransitionContext
    ) {
        let owner = context.resumedDeferral.map {
            RouterPresentationCompletionOwner.deferral($0)
        } ?? .transition(transitionID)
        let dismissed = presentationIDs(in: before).subtracting(presentationIDs(in: after))
        for id in dismissed {
            let waiter = presentationWaiters.removeValue(forKey: id)
            waiter?.finishAfterDismissal(owner)
        }
    }

    private func presentationID(at path: RouterScopePath) -> UUID? {
        Self.presentationID(in: state, at: path)
    }

    private static func presentationID(
        in state: RouterState<R>,
        at path: RouterScopePath
    ) -> UUID? {
        guard case .stack(let stack) = state.node(at: path) else { return nil }
        return stack.presentation?.id
    }

    private func presentationIDs(in state: RouterState<R>) -> Set<UUID> {
        var ids: Set<UUID> = []
        collectPresentationIDs(in: state.root, into: &ids)
        for window in state.windows {
            collectPresentationIDs(in: window.node, into: &ids)
        }
        if let immersiveSpace = state.immersiveSpace {
            collectPresentationIDs(in: immersiveSpace.node, into: &ids)
        }
        return ids
    }

    private func collectPresentationIDs(
        in node: RouterNode<R>,
        into ids: inout Set<UUID>
    ) {
        switch node {
        case .stack(let stack):
            if let id = stack.presentation?.id {
                ids.insert(id)
            }
        case .container(let container):
            for branch in container.branches {
                collectPresentationIDs(in: branch.node, into: &ids)
            }
        }
    }

    private func cancelPresentation(id: UUID, at path: RouterScopePath) async {
        let waiter = presentationWaiters.removeValue(forKey: id)
        let requestIDs = presentationRequestIDs[id] ?? []
        for requestID in requestIDs {
            cancelRequest(requestID)
        }
        for requestID in requestIDs {
            await waitUntilRequestFinishes(requestID)
        }
        let deferralIDs = deferredRequests.compactMap { entry in
            deferredPresentationTarget(in: entry.value.action) == .present(id)
                ? entry.key
                : nil
        }
        for deferralID in deferralIDs {
            _ = await cancelDeferred(deferralID)
        }
        waiter?.finishCancelled()
        guard presentationID(at: path) == id else { return }
        _ = await perform(
            RouterAction.dismissPresentation.inScope(path),
            context: .init(),
            expectedRevision: nil,
            bypassesPolicies: false,
            executionPrecondition: Self.presentationIdentityPrecondition(id: id, at: path)
        )
    }

    func registerPresentationRequest(
        _ presentationID: UUID,
        transitionID: RouterTransitionID
    ) {
        presentationRequestIDs[presentationID, default: []].insert(transitionID)
    }

    func unregisterPresentationRequest(
        _ presentationID: UUID,
        transitionID: RouterTransitionID
    ) {
        presentationRequestIDs[presentationID]?.remove(transitionID)
        if presentationRequestIDs[presentationID]?.isEmpty == true {
            presentationRequestIDs.removeValue(forKey: presentationID)
        }
    }

    static func presentationIdentityPrecondition(
        id: UUID,
        at path: RouterScopePath
    ) -> RouterRequestPrecondition<R> {
        { state in
            let actual = presentationID(in: state, at: path)
            guard actual == id else {
                return .mutation(.presentationIdentityMismatch(
                    scope: path,
                    expected: id,
                    actual: actual
                ))
            }
            return nil
        }
    }

    private static func combinePresentationPreconditions(
        _ first: @escaping RouterRequestPrecondition<R>,
        _ second: RouterRequestPrecondition<R>?
    ) -> RouterRequestPrecondition<R> {
        { state in first(state) ?? second?(state) }
    }

    func deferredPresentationTarget(
        in action: RouterAction<R>,
        path: RouterScopePath = .root
    ) -> DeferredPresentationTarget? {
        switch action {
        case .present(let presentation):
            return .present(presentation.id)
        case .dismissPresentation:
            return .dismiss(path)
        case .scoped(let scope, let child):
            return deferredPresentationTarget(in: child, path: path.appending(scope))
        case .windowScoped(let id, let child):
            return deferredPresentationTarget(in: child, path: .window(id))
        case .immersiveSpaceScoped(let id, let child):
            return deferredPresentationTarget(in: child, path: .immersiveSpace(id))
        default:
            return nil
        }
    }
}

enum DeferredPresentationTarget: Equatable {
    case present(UUID)
    case dismiss(RouterScopePath)
}
