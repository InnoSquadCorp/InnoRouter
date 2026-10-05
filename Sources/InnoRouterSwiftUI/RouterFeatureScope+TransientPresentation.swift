import InnoRouterCore

@MainActor
extension RouterFeatureScope {
    public var presentationFamily: RouterPresentationFamily<Child>? { observedPresentationFamily }

    var observedPresentationFamily: RouterPresentationFamily<Child>? {
        guard case .stack(let stack) = node else { return nil }
        return stack.presentationFamily
    }

    public func present<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>
    ) async -> RouterPresentationOutcome<Value> {
        await presentFeature(request, features: [], executionPrecondition: nil)
    }

    func presentFeature<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterPresentationOutcome<Value> {
        guard node != nil else { return .rejected(.featureProjection(.routeMismatch(namespace: mapping.namespace))) }
        return await parent.presentFeature(request, features: [featureCatalogEntry] + features,
                                           executionPrecondition: parentPrecondition(executionPrecondition))
    }

    public func presentationHandle() -> RouterPresentationHandle? {
        guard node != nil else { return nil }
        return parent.presentationHandle()
    }

    public func selectPresentationAction(
        _ actionID: RouterPresentationActionID, using handle: RouterPresentationHandle,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<Child> {
        await performPresentationAction(.selectPresentationAction(presentationID: handle.id, actionID: actionID),
                                        using: handle, context: context, features: [], executionPrecondition: nil)
    }

    public func dismissPresentation(
        using handle: RouterPresentationHandle, context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<Child> {
        await performPresentationAction(.dismissPresentation, using: handle, context: context,
                                        features: [], executionPrecondition: nil)
    }

    func performPresentationAction(
        _ action: RouterAction<Child>, using handle: RouterPresentationHandle,
        context: RouterTransitionContext, features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterOutcome<Child> {
        do {
            let mapped = try mapping.embed(action)
            return map(await parent.performPresentationAction(
                mapped, using: handle, context: context, features: [featureCatalogEntry] + features,
                executionPrecondition: parentPrecondition(executionPrecondition)
            ))
        } catch let failure as RouterFeatureProjectionError {
            return reject(.featureProjection(failure))
        } catch {
            return reject(.featureProjection(.invalidFeatureState(namespace: mapping.namespace)))
        }
    }
}
