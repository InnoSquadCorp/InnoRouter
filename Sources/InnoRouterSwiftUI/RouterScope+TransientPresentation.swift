import InnoRouterCore

@MainActor
extension RouterScope {
    public func present<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>
    ) async -> RouterPresentationOutcome<Value> {
        guard let store else { return .cancelled }
        return await store.present(request, at: path, executionPrecondition: combinedExecutionPrecondition(nil))
    }

    func presentFeature<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value> {
        guard let store else { return .cancelled }
        return await store.present(
            request, at: path, executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(scope: path, lifetime: sceneLifetime, features: features)
        )
    }

    public func presentationHandle() -> RouterPresentationHandle? {
        guard matchesCurrentLifetime else { return nil }
        return store?.presentationHandle(at: path)
    }

    public func selectPresentationAction(
        _ actionID: RouterPresentationActionID, using handle: RouterPresentationHandle,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await performPresentationAction(.selectPresentationAction(presentationID: handle.id, actionID: actionID),
                                        using: handle, context: context, features: [], executionPrecondition: nil)
    }

    public func dismissPresentation(
        using handle: RouterPresentationHandle, context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await performPresentationAction(.dismissPresentation, using: handle, context: context,
                                        features: [], executionPrecondition: nil)
    }

    func performPresentationAction(
        _ action: RouterAction<R>, using handle: RouterPresentationHandle,
        context: RouterTransitionContext, features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R> {
        guard let store else { return reject(.mutation(.expiredScope(path))) }
        guard handle.scope == path else {
            return reject(.mutation(.presentationIdentityMismatch(scope: path, expected: handle.id, actual: presentationFamily?.id)))
        }
        let captured = store.presentationHandlePrecondition(handle)
        let precondition: RouterRequestPrecondition<R> = { state in captured(state) ?? executionPrecondition?(state) }
        if features.isEmpty {
            return await perform(action, context: context, expectedRevision: nil, executionPrecondition: precondition)
        }
        return await performFeatureAction(action, context: context, expectedRevision: nil,
                                          features: features, executionPrecondition: precondition)
    }
}
