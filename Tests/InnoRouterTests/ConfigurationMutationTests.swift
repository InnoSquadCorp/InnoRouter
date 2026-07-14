// MARK: - ConfigurationMutationTests.swift
// InnoRouterTests - covers `var public` exposure of the three
// `*Configuration` structs introduced in v4.0.0.
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum CfgRoute: Route {
    case home
}

@Suite("Configuration mutation")
@MainActor
struct ConfigurationMutationTests {

    @Test("NavigationStoreConfiguration observer can be patched after construction")
    func navigationConfig_observerIsPatchable() {
        var config = NavigationStoreConfiguration<CfgRoute>()
        #expect(config.onEvent == nil)

        config.onEvent = { _ in }

        #expect(config.onEvent != nil)
    }

    @Test("ModalStoreConfiguration observer can be patched after construction")
    func modalConfig_observerIsPatchable() {
        var config = ModalStoreConfiguration<CfgRoute>()
        #expect(config.onEvent == nil)

        config.onEvent = { _ in }

        #expect(config.onEvent != nil)
    }

    @Test("FlowStoreConfiguration nested configs can be patched after construction")
    func flowConfig_nestedConfigsArePatchable() {
        var config = FlowStoreConfiguration<CfgRoute>()
        #expect(config.navigation.onEvent == nil)
        #expect(config.modal.onEvent == nil)
        #expect(config.onEvent == nil)

        config.navigation.onEvent = { _ in }
        config.modal.onEvent = { _ in }
        config.onEvent = { _ in }

        #expect(config.navigation.onEvent != nil)
        #expect(config.modal.onEvent != nil)
        #expect(config.onEvent != nil)
    }

    @Test("Patched configuration constructs a working store")
    func patchedConfig_constructsStore() {
        var config = NavigationStoreConfiguration<CfgRoute>()
        var observed = 0
        config.onEvent = { event in
            guard case .changed = event else { return }
            observed += 1
        }

        let store = NavigationStore<CfgRoute>(configuration: config)
        store.execute(.push(.home))

        #expect(observed == 1)
        #expect(store.state.path == [.home])
    }
}
