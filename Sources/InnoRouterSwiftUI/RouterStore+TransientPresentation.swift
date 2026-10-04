import Foundation

import InnoRouterCore

@MainActor
extension RouterStore {
    /// Displays immutable action descriptors and awaits one typed terminal value.
    /// The router returns Values; it never invokes an application action closure.
    public func present<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>,
        at path: RouterScopePath = .root
    ) async -> RouterPresentationOutcome<Value> {
        await present(request, at: path, executionPrecondition: nil)
    }

    package func present<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>,
        at path: RouterScopePath,
        executionPrecondition: RouterRequestPrecondition<R>?,
        requestSemantics: RouterRequestSemantics<R> = .action
    ) async -> RouterPresentationOutcome<Value> {
        do { try resourceBudget.validateTransientRequest(request) }
        catch { return .rejected(.resourceLimit(error)) }
        let content = RouterTransientPresentationContent(
            title: request.title, message: request.message, actions: request.actions.map(\.descriptor)
        )
        do { try content.validate() }
        catch { return .rejected(.mutation(.invalidTargetState(error))) }
        let presentation = RouterTransientPresentation(content: content)
        let action: RouterAction<R> = request.kind == .alert
            ? .presentAlert(presentation) : .presentConfirmationDialog(presentation)
        return await awaitPresentation(
            action, id: presentation.id, at: path, expecting: Value.self,
            selectionActions: request.actions,
            executionPrecondition: executionPrecondition, requestSemantics: requestSemantics
        )
    }

    func transientSelectionTarget(
        in action: RouterAction<R>, path: RouterScopePath = .root
    ) -> (path: RouterScopePath, id: UUID, actionID: RouterPresentationActionID)? {
        switch action {
        case .selectPresentationAction(let id, let actionID): (path, id, actionID)
        case .scoped(let scope, let child): transientSelectionTarget(in: child, path: path.appending(scope))
        case .presentationScoped(let id, let child): transientSelectionTarget(in: child, path: path.appendingPresentation(id))
        case .windowScoped(let id, let child): transientSelectionTarget(in: child, path: .window(id))
        case .immersiveSpaceScoped(let id, let child): transientSelectionTarget(in: child, path: .immersiveSpace(id))
        default: nil
        }
    }

    /// Runs only after pure reduction and complete resource/structural admission.
    func prepareTransientSelection(
        for action: RouterAction<R>, owner: RouterPresentationCompletionOwner
    ) -> RouterTransientSelectionAdmission<R> {
        guard let target = transientSelectionTarget(in: action),
              let waiter = presentationWaiters[target.id] else { return .none }
        let lifetime = presentationLifetimePrecondition(id: target.id, at: target.path)
        let result = waiter.resultPrecondition
        let identity = waiter.identity
        let precondition: RouterRequestPrecondition<R> = { [weak self] state in
            if let rejection = lifetime(state) { return rejection }
            guard self?.presentationWaiters[target.id]?.identity == identity else {
                return .mutation(.expiredPresentation(target.id, scope: target.path))
            }
            return result()
        }
        if let rejection = precondition(state) { return .rejected(rejection) }
        guard let prepare = waiter.prepareAction else {
            return .rejected(.mutation(.unknownPresentationAction(target.path)))
        }
        switch prepare(target.actionID, owner) {
        case .prepared:
            return .ready(.init(precondition: precondition, clear: { waiter.clearPreparedValue(owner) }))
        case .typeMismatch: return .rejected(.mutation(.unknownPresentationAction(target.path)))
        case .alreadyPending: return .rejected(.mutation(.presentationCompletionPending(target.id)))
        }
    }
}

@MainActor
struct RouterTransientSelectionPreparation<R: Route> {
    let precondition: RouterRequestPrecondition<R>
    let clear: () -> Void
}

@MainActor
enum RouterTransientSelectionAdmission<R: Route> {
    case none
    case ready(RouterTransientSelectionPreparation<R>)
    case rejected(RouterRejectionReason)
}
