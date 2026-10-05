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
        return await awaitPresentation(
            .present(presentation), id: presentation.id, at: path,
            expecting: expecting, selectionActions: nil,
            executionPrecondition: executionPrecondition,
            requestSemantics: requestSemantics
        )
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
        if let rejection = executionPrecondition?(state) {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        guard let presentationID = presentationID(at: path) else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        guard case .stack(let stack) = state.node(at: path), stack.presentation != nil else {
            throw RouterPresentationCompletionError.dismissalRejected(.mutation(.expectedNavigationPresentation(path)))
        }
        guard let erasedWaiter = presentationWaiters[presentationID] else {
            throw RouterPresentationCompletionError.presentationWasNotAwaited(presentationID)
        }
        if let rejection = erasedWaiter.resultPrecondition() {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        let resultPrecondition = erasedWaiter.resultPrecondition
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
                presentationLifetimePrecondition(id: presentationID, at: path),
                { state in resultPrecondition() ?? executionPrecondition?(state) }
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
        owner: RouterPresentationCompletionOwner,
        nextOwner: RouterPresentationCompletionOwner
    ) {
        guard case .dismiss(let path) = deferredPresentationTarget(in: action),
              let presentationID = presentationID(at: path),
              let waiter = presentationWaiters[presentationID] else { return }
        waiter.movePreparedValue(owner, nextOwner)
    }

    func finishDismissedPresentations(
        ids: Set<UUID>,
        before: RouterState<R>,
        action: RouterAction<R>,
        owner: RouterPresentationCompletionOwner
    ) {
        let directTarget: UUID?
        if case .dismiss(let path) = deferredPresentationTarget(in: action) {
            directTarget = Self.presentationID(in: before, at: path)
        } else {
            directTarget = nil
        }
        for id in ids {
            let waiter = presentationWaiters.removeValue(forKey: id)
            if id == directTarget {
                waiter?.finishAfterDismissal(owner)
            } else {
                waiter?.finishCancelled()
            }
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
        return stack.presentationFamily?.id
    }

    func cancelPresentation(id: UUID, at path: RouterScopePath, waiterIdentity: UUID) async {
        guard presentationWaiters[id]?.identity == waiterIdentity else { return }
        let lifetimePrecondition = presentationLifetimePrecondition(id: id, at: path)
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
        guard presentationID(at: path) == id, lifetimePrecondition(state) == nil else { return }
        _ = await perform(
            RouterAction.dismissPresentation.inScope(path),
            context: .init(),
            expectedRevision: nil,
            bypassesPolicies: false,
            executionPrecondition: lifetimePrecondition
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

    func presentationLifetimePrecondition(
        id: UUID,
        at path: RouterScopePath
    ) -> RouterRequestPrecondition<R> {
        presentationRuntimePrecondition(id: id, at: path)
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
        case .presentAlert(let presentation), .presentConfirmationDialog(let presentation):
            return .present(presentation.id)
        case .dismissPresentation, .selectPresentationAction:
            return .dismiss(path)
        case .scoped(let scope, let child):
            return deferredPresentationTarget(in: child, path: path.appending(scope))
        case .presentationScoped(let id, let child):
            return deferredPresentationTarget(in: child, path: path.appendingPresentation(id))
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
