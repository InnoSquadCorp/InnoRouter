// MARK: - RouterStore+PlatformAdaptation.swift
// InnoRouterSwiftUI - bounded native platform adaptation reporting
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

package struct RouterPlatformAdaptationHistory {
    private static let capacity = 256

    private var adaptations: Set<RouterPlatformAdaptation> = []
    private var order: [RouterPlatformAdaptation] = []

    package mutating func insert(_ adaptation: RouterPlatformAdaptation) -> Bool {
        guard adaptations.insert(adaptation).inserted else { return false }
        order.append(adaptation)
        if order.count > Self.capacity {
            adaptations.remove(order.removeFirst())
        }
        return true
    }
}

extension RouterStore {
    package func reportPlatformAdaptation(_ adaptation: RouterPlatformAdaptation) {
        guard platformAdaptationHistory.insert(adaptation) else { return }
        emit(
            .platformAdapted(
                eventID: runtimeDependencies.makeTransitionID(),
                adaptation: adaptation,
                revision: revision
            )
        )
    }
}
