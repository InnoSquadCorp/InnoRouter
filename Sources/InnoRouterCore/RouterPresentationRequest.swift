// MARK: - RouterPresentationRequest.swift
// InnoRouterCore - compile-time presentation result contracts
// Copyright © 2026 Inno Squad. All rights reserved.

/// A route presentation whose terminal value is known at compile time.
///
/// `@Router` generates these values for cases annotated with
/// `@PresentationResult`. The same request should be used to present and to
/// finish the destination, preventing an unrelated result type or route from
/// completing the active presentation.
public struct RouterPresentationRequest<R: Route, Value: Sendable>: Sendable {
    public var route: R
    public var style: RouterPresentationStyle
    public var options: RouterPresentationOptions

    public init(
        route: R,
        style: RouterPresentationStyle = .sheet,
        options: RouterPresentationOptions = .init()
    ) {
        self.route = route
        self.style = style
        self.options = options
    }

    /// Returns a copy using a different native presentation style.
    public func style(_ style: RouterPresentationStyle) -> Self {
        var copy = self
        copy.style = style
        return copy
    }

    /// Returns a copy using different native presentation behavior.
    public func options(_ options: RouterPresentationOptions) -> Self {
        var copy = self
        copy.options = options
        return copy
    }
}

extension RouterPresentationRequest: Equatable where Value: Equatable {}
extension RouterPresentationRequest: Hashable where Value: Hashable {}
