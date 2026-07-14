// MARK: - FlowPlanApplicationTests.swift
// InnoRouterTests - FlowStore.apply(_ plan:)
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum FlowPlanRoute: Route {
    case start
    case second
    case sheetStep
    case coverStep
    case queuedStep
}

@Suite("FlowPlan Application Tests")
struct FlowPlanApplicationTests {

    @Test("apply seeds stack and modal tail from a valid plan")
    @MainActor
    func applyValidPlan() {
        let store = FlowStore<FlowPlanRoute>()
        let plan = FlowPlan<FlowPlanRoute>(steps: [
            .push(.start),
            .push(.second),
            .sheet(.sheetStep)
        ])

        let result = store.apply(plan)

        #expect(store.path == plan.steps)
        #expect(store.navigationStore.state.path == [.start, .second])
        #expect(store.modalStore.currentPresentation?.route == .sheetStep)
        #expect(result == .applied(path: plan.steps))
    }

    @Test("apply with invalid plan emits invalidResetPath rejection")
    @MainActor
    func applyInvalidPlanRejected() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let store = FlowStore<FlowPlanRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .intentRejected(_, let reason) = event else { return }
                    rejections.withLock { $0.append(reason) }
                }
            )
        )
        let invalid = FlowPlan<FlowPlanRoute>(steps: [
            .sheet(.sheetStep),
            .push(.second)
        ])

        let result = store.apply(invalid)

        #expect(store.path.isEmpty)
        #expect(rejections.withLock { $0 } == [.invalidResetPath])
        #expect(result == .rejected(currentPath: []))
    }

    @Test("apply with empty plan clears stack and modal")
    @MainActor
    func applyEmptyPlanClears() {
        let store = FlowStore<FlowPlanRoute>()
        store.send(.push(.start))
        store.send(.presentSheet(.sheetStep))

        let result = store.apply(FlowPlan<FlowPlanRoute>())

        #expect(store.path.isEmpty)
        #expect(store.navigationStore.state.path.isEmpty)
        #expect(store.modalStore.currentPresentation == nil)
        #expect(result == .applied(path: []))
    }

    @Test("apply supports cover tail too")
    @MainActor
    func applyCoverTailPlan() {
        let store = FlowStore<FlowPlanRoute>()
        store.apply(FlowPlan<FlowPlanRoute>(steps: [.push(.start), .cover(.coverStep)]))

        #expect(store.modalStore.currentPresentation?.style == .fullScreenCover)
        #expect(store.modalStore.currentPresentation?.route == .coverStep)
    }

    @Test("apply clears queued presentations when target modal tail already matches current modal")
    @MainActor
    func applyClearsStaleQueuedPresentations() {
        let store = FlowStore<FlowPlanRoute>()
        store.send(.push(.start))
        store.send(.presentSheet(.sheetStep))
        store.send(.presentSheet(.queuedStep))

        store.apply(FlowPlan<FlowPlanRoute>(steps: [.push(.start), .sheet(.sheetStep)]))

        #expect(store.path == [.push(.start), .sheet(.sheetStep)])
        #expect(store.modalStore.currentPresentation?.route == .sheetStep)
        #expect(store.modalStore.queuedPresentations.isEmpty)
    }

    @Test("apply keeps a matching modal tail without lifecycle churn when queue is empty")
    @MainActor
    func applyMatchingModalTailIsNoopForModalLifecycle() {
        let presented = Mutex<[FlowPlanRoute]>([])
        let dismissed = Mutex<[ModalDismissalReason]>([])
        let store = FlowStore<FlowPlanRoute>(
            configuration: .init(
                modal: .init(
                    onEvent: { event in
                        switch event {
                        case .presented(let presentation):
                            presented.withLock { $0.append(presentation.route) }
                        case .dismissed(_, let reason):
                            dismissed.withLock { $0.append(reason) }
                        default:
                            break
                        }
                    }
                )
            )
        )
        store.send(.push(.start))
        store.send(.presentSheet(.sheetStep))

        let presentedMarker = presented.withLock { $0.count }
        let dismissedMarker = dismissed.withLock { $0.count }
        let beforeID = store.modalStore.currentPresentation?.id

        let result = store.apply(
            FlowPlan<FlowPlanRoute>(steps: [.push(.start), .sheet(.sheetStep)])
        )

        let newPresented = presented.withLock { Array($0.dropFirst(presentedMarker)) }
        let newDismissed = dismissed.withLock { Array($0.dropFirst(dismissedMarker)) }

        #expect(result == .applied(path: [.push(.start), .sheet(.sheetStep)]))
        #expect(beforeID == store.modalStore.currentPresentation?.id)
        #expect(newPresented.isEmpty)
        #expect(newDismissed.isEmpty)
    }

    @Test("apply with the same push path and modal tail does not emit pathChanged")
    @MainActor
    func applyMatchingPlanDoesNotEmitPathChanged() {
        let changes = Mutex<[([RouteStep<FlowPlanRoute>], [RouteStep<FlowPlanRoute>])]>([])
        let store = FlowStore<FlowPlanRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .pathChanged(let old, let new) = event else { return }
                    changes.withLock { $0.append((old, new)) }
                }
            )
        )
        store.send(.push(.start))
        store.send(.presentSheet(.sheetStep))

        let marker = changes.withLock { $0.count }
        let result = store.apply(
            FlowPlan<FlowPlanRoute>(steps: [.push(.start), .sheet(.sheetStep)])
        )

        #expect(result == .applied(path: [.push(.start), .sheet(.sheetStep)]))
        #expect(changes.withLock { Array($0.dropFirst(marker)) }.isEmpty)
    }
}
