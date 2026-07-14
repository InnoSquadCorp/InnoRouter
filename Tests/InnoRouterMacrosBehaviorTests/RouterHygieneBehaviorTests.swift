// MARK: - RouterHygieneBehaviorTests.swift
// InnoRouterMacrosBehaviorTests - @Router qualified-name hygiene

#if canImport(InnoRouterMacrosPlugin)

import SwiftUI
import Testing

import InnoRouterMacros

// These declarations intentionally shadow every unqualified name that the
// generated router witness needs. The macro must bind to the framework and
// SwiftUI symbols explicitly rather than to consumer-local declarations.
private protocol DestinationRoute {}
private protocol View {}

@resultBuilder
private enum ViewBuilder {
    static func buildBlock(_ components: String...) -> String {
        components.joined()
    }
}

@Router
private enum HygienicRouterRoute {
    case settings

    var destination: some SwiftUI.View {
        Text("Settings")
    }
}

@Suite("@Router qualified-name hygiene")
struct RouterHygieneBehaviorTests {
    @Test("Consumer-local names cannot capture generated symbols")
    @MainActor
    func qualifiedGeneratedSymbols() {
        _ = HygienicRouterRoute.destination(for: .settings)

        let host = RouterHost(HygienicRouterRoute.self) {
            Text("Root")
        }
        _ = host.body
    }
}

#endif
