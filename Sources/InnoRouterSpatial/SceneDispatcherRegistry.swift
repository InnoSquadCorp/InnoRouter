// MARK: - SceneDispatcherRegistry.swift
// InnoRouterSpatial — primary/fallback dispatcher election.

import Foundation

internal struct SceneDispatcherRegistry: Equatable {
    internal private(set) var primaryHost: UUID?
    internal private(set) var fallbackAnchors: [UUID] = []

    internal var electedDispatcherToken: UUID? {
        primaryHost ?? fallbackAnchors.first
    }

    internal mutating func registerPrimaryHost(_ token: UUID) -> Bool {
        if let primaryHost, primaryHost != token {
            return false
        }

        primaryHost = token
        return true
    }

    internal mutating func unregisterPrimaryHost(_ token: UUID) {
        if primaryHost == token {
            primaryHost = nil
        }
    }

    internal mutating func registerFallbackAnchor(_ token: UUID) {
        if fallbackAnchors.contains(token) == false {
            fallbackAnchors.append(token)
        }
    }

    internal mutating func unregisterFallbackAnchor(_ token: UUID) {
        fallbackAnchors.removeAll { $0 == token }
    }

    internal func canClaim(_ token: UUID) -> Bool {
        electedDispatcherToken == token
    }
}
