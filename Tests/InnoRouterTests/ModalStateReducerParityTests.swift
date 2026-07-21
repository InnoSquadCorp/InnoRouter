// MARK: - ModalStateReducerParityTests.swift
// InnoRouterTests - live ModalStore and pure reducer transition parity.
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum ModalParityRoute: Route {
    case profile
    case onboarding
    case settings
}

@Suite("Modal state reducer parity")
@MainActor
struct ModalStateReducerParityTests {
    @Test("live execution matches the pure reducer across every command kind")
    func liveExecutionMatchesReducer() {
        let profile = ModalPresentation<ModalParityRoute>(route: .profile, style: .sheet)
        let onboarding = ModalPresentation<ModalParityRoute>(
            route: .onboarding,
            style: .fullScreenCover
        )
        let settings = ModalPresentation<ModalParityRoute>(route: .settings, style: .sheet)
        let replacement = ModalPresentation(
            id: profile.id,
            route: ModalParityRoute.settings,
            style: .fullScreenCover
        )
        let commands: [ModalCommand<ModalParityRoute>] = [
            .replaceCurrent(settings),
            .dismissCurrent(reason: .dismiss),
            .dismissAll,
            .present(profile),
            .present(onboarding),
            .replaceCurrent(replacement),
            .dismissCurrent(reason: .systemDismiss),
            .dismissAll,
        ]

        let store = ModalStore<ModalParityRoute>()
        var expectedState = ModalExecutionState<ModalParityRoute>(
            currentPresentation: nil,
            queuedPresentations: []
        )

        for command in commands {
            let expected = ModalStateReducer.apply(command, to: expectedState)
            let actualResult = store.execute(command)

            #expect(actualResult == expected.result)
            #expect(store.currentPresentation == expected.stateAfter.currentPresentation)
            #expect(store.queuedPresentations == expected.stateAfter.queuedPresentations)
            expectedState = expected.stateAfter
        }
    }
}
