// Typed presentation operations share their scope's immutable runtime authority.
import InnoRouterCore

extension RouterScope {
    /// Presents a route and suspends until its exact presentation returns a
    /// value, is dismissed, is cancelled, or fails policy admission.
    public func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle = .sheet,
        options: RouterPresentationOptions = .init(),
        expecting: Value.Type = Value.self
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            route,
            style: style,
            options: options,
            expecting: expecting,
            executionPrecondition: nil
        )
    }

    func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value> {
        guard let store else { return .cancelled }
        if let rejection = resourceAdmissionRejection { return .rejected(rejection) }
        return await store.present(
            route,
            style: style,
            options: options,
            at: path,
            expecting: expecting,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    func presentFeature<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value> {
        guard let store else { return .cancelled }
        if let rejection = resourceAdmissionRejection { return .rejected(rejection) }
        return await store.present(
            route,
            style: style,
            options: options,
            at: path,
            expecting: expecting,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            )
        )
    }

    /// Presents a macro-generated, result-typed request.
    public func present<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            request.route,
            style: request.style,
            options: request.options,
            expecting: Value.self
        )
    }

    /// Completes the exact presentation active in this scope.
    public func finishPresentation<Value: Sendable>(
        returning value: Value
    ) async throws {
        try await finishPresentation(returning: value, executionPrecondition: nil)
    }

    func finishPresentation<Value: Sendable>(
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        if let rejection = resourceAdmissionRejection {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        try await store.finishPresentation(
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    /// Completes only when the active route matches the typed request.
    public func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value
    ) async throws {
        try await finishPresentation(
            request,
            returning: value,
            executionPrecondition: nil
        )
    }

    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        if let rejection = resourceAdmissionRejection {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        try await store.finishPresentation(
            request,
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    func finishFeaturePresentation<Value: Sendable>(
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        if let rejection = resourceAdmissionRejection {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        try await store.finishPresentation(
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            )
        )
    }

    func finishFeaturePresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        if let rejection = resourceAdmissionRejection {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        try await store.finishPresentation(
            request,
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            )
        )
    }
}
