// MARK: - RouterFeatureScope+ScenarioSemantics.swift
// InnoRouterSwiftUI - nested feature presentation ownership propagation
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

@MainActor
extension RouterFeatureScope {
    func presentFeature<Value: Sendable>(
        _ route: Child,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        features childFeatures: [RouterFeatureCatalogEntry],
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterPresentationOutcome<Value> {
        guard node != nil else {
            return .rejected(.featureProjection(
                .routeMismatch(namespace: mapping.namespace)
            ))
        }
        return await parent.presentFeature(
            mapping.route.embed(route),
            style: style,
            options: options,
            expecting: expecting,
            features: [featureCatalogEntry] + childFeatures,
            executionPrecondition: parentPrecondition(childPrecondition)
        )
    }

    func finishFeaturePresentation<Value: Sendable>(
        returning value: Value,
        features childFeatures: [RouterFeatureCatalogEntry],
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async throws {
        guard node != nil else { throw projectionCompletionError() }
        try await parent.finishFeaturePresentation(
            returning: value,
            features: [featureCatalogEntry] + childFeatures,
            executionPrecondition: parentPrecondition(childPrecondition)
        )
    }

    func finishFeaturePresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<Child, Value>,
        returning value: Value,
        features childFeatures: [RouterFeatureCatalogEntry],
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async throws {
        guard node != nil else { throw projectionCompletionError() }
        let parentRequest = RouterPresentationRequest<Parent, Value>(
            route: mapping.route.embed(request.route),
            style: request.style,
            options: request.options
        )
        try await parent.finishFeaturePresentation(
            parentRequest,
            returning: value,
            features: [featureCatalogEntry] + childFeatures,
            executionPrecondition: parentPrecondition(childPrecondition)
        )
    }
}
