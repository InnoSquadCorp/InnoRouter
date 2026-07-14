// MARK: - LocalizedDescriptionSurfaceTests.swift
// InnoRouterTests - user-facing reason descriptions
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouter
import InnoRouterDeepLink

@Suite("Localized description surfaces")
struct LocalizedDescriptionSurfaceTests {
    @Test("navigation cancellation exposes localizedDescription")
    func navigationCancellationDescription() {
        let reason: NavigationCancellationReason<TestRoute> = .conditionFailed
        #expect(!reason.localizedDescription.isEmpty)
    }

    @Test("modal cancellation exposes localizedDescription")
    func modalCancellationDescription() {
        let reason: ModalCancellationReason<TestModalRoute> = .custom("Blocked")
        #expect(reason.localizedDescription == "Blocked")
    }

    @Test("flow rejection exposes localizedDescription")
    func flowRejectionDescription() {
        #expect(FlowRejectionReason.pushBlockedByModalTail.localizedDescription.contains("modal"))
        #expect(FlowRejectionReason.reentrantApply.localizedDescription.contains("reentrant"))
    }

    @Test("deep-link rejection exposes localizedDescription")
    func deepLinkRejectionDescription() {
        let reason = DeepLinkRejectionReason.inputLimitExceeded(
            .queryItemCountExceeded(actual: 3, max: 1)
        )
        #expect(reason.localizedDescription.contains("query"))
    }
}
