// MARK: - ExecutionContractSpecTests.swift
// InnoRouterTests - public execution contract specs
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouterCore
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterDeepLink
import InnoRouterDeepLinkEffects

private enum ContractRoute: String, Route, Codable {
    case home
    case detail
    case settings
    case secure
    case legal
}

@MainActor
private final class ContractCleanupMiddleware: NavigationMiddleware, NavigationMiddlewareDiscardCleanup {
    typealias RouteType = ContractRoute

    private(set) var didExecuteCommands: [NavigationCommand<ContractRoute>] = []
    private(set) var discardedCommands: [NavigationCommand<ContractRoute>] = []

    func willExecute(
        _ command: NavigationCommand<ContractRoute>,
        state: RouteStack<ContractRoute>
    ) -> NavigationInterception<ContractRoute> {
        .proceed(command)
    }

    func didExecute(
        _ command: NavigationCommand<ContractRoute>,
        result: NavigationResult<ContractRoute>,
        state: RouteStack<ContractRoute>
    ) -> NavigationResult<ContractRoute> {
        didExecuteCommands.append(command)
        return result
    }

    func discardExecution(
        _ command: NavigationCommand<ContractRoute>,
        result: NavigationResult<ContractRoute>,
        state: RouteStack<ContractRoute>
    ) {
        discardedCommands.append(command)
    }
}

private enum ContractFlowEvent: Equatable {
    case navigationChanged
    case modalPresented
    case modalDismissed
    case modalQueueChanged
    case pathChanged
    case intentRejected(FlowRejectionReason)
}

private func normalizeContractFlowEvent(
    _ event: FlowEvent<ContractRoute>
) -> ContractFlowEvent? {
    switch event {
    case .navigation(.changed):
        return .navigationChanged
    case .modal(.presented):
        return .modalPresented
    case .modal(.dismissed):
        return .modalDismissed
    case .modal(.queueChanged):
        return .modalQueueChanged
    case .pathChanged:
        return .pathChanged
    case .intentRejected(_, let reason):
        return .intentRejected(reason)
    case .navigation, .modal:
        return nil
    }
}

@Suite("Execution Contract Spec Tests")
struct ExecutionContractSpecTests {

    @Test("Single .sequence is command algebra, not a transaction")
    @MainActor
    func singleSequencePreservesPartialProgress() {
        let store = NavigationStore<ContractRoute>()

        let result = store.execute(
            .sequence([.push(.home), .popTo(.settings), .push(.detail)])
        )

        #expect(
            result == .multiple([.success, .routeNotFound(.settings), .success])
        )
        #expect(store.state.path == [.home, .detail])
    }

    @Test("Batch stopOnFailure controls whether later commands run after a failure")
    @MainActor
    func batchStopOnFailureControlsContinuation() {
        let commands: [NavigationCommand<ContractRoute>] = [
            .push(.home),
            .popTo(.settings),
            .push(.detail),
        ]

        let continuingStore = NavigationStore<ContractRoute>()
        let continuingBatch = continuingStore.executeBatch(commands, stopOnFailure: false)
        #expect(continuingBatch.results == [.success, .routeNotFound(.settings), .success])
        #expect(!continuingBatch.hasStoppedOnFailure)
        #expect(continuingStore.state.path == [.home, .detail])

        let stoppingStore = NavigationStore<ContractRoute>()
        let stoppingBatch = stoppingStore.executeBatch(commands, stopOnFailure: true)
        #expect(stoppingBatch.results == [.success, .routeNotFound(.settings)])
        #expect(stoppingBatch.hasStoppedOnFailure)
        #expect(stoppingStore.state.path == [.home])
    }

    @Test("Transactions rollback atomically and keep discarded legs off the public didExecute path")
    @MainActor
    func transactionRollbackIsCommitOnlyPublicObservation() {
        let middleware = ContractCleanupMiddleware()
        let store = NavigationStore<ContractRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(middleware: AnyNavigationMiddleware(middleware), debugName: "cleanup")
                ]
            )
        )

        let transaction = store.executeTransaction([
            .push(.home),
            .popTo(.settings),
        ])

        #expect(!transaction.isCommitted)
        #expect(transaction.failureIndex == 1)
        #expect(transaction.results == [.success, .routeNotFound(.settings)])
        #expect(transaction.executedCommands == [.push(.home), .popTo(.settings)])
        #expect(transaction.stateBefore.path.isEmpty)
        #expect(transaction.stateAfter.path.isEmpty)
        #expect(store.state.path.isEmpty)
        #expect(middleware.didExecuteCommands.isEmpty)
        #expect(middleware.discardedCommands == [.push(.home), .popTo(.settings)])
    }

    @Test("FlowStore successful mutations emit inner events before flow-level path changes")
    @MainActor
    func flowStoreSuccessUsesMergedStreamContract() async {
        let store = FlowStore<ContractRoute>()
        let recorder = FlowEventRecorder(store: store)
        defer { recorder.cancel() }

        let mark = recorder.mark()
        store.send(.push(.home))

        let normalized = await recorder.rawEvents(since: mark, minimumCount: 2)
            .compactMap(normalizeContractFlowEvent)

        #expect(normalized == [.navigationChanged, .pathChanged])
    }

    @Test("FlowStore queued-modal promotion merges modal lifecycle and settled flow events on one stream")
    @MainActor
    func flowStorePromotionMergedStreamContract() async {
        let store = FlowStore<ContractRoute>()
        store.send(.presentSheet(.legal))
        store.send(.presentSheet(.detail))

        let recorder = FlowEventRecorder(store: store)
        defer { recorder.cancel() }

        let mark = recorder.mark()
        store.send(.backOrPushDismissingModal(.home))

        let normalized = await recorder.rawEvents(since: mark, minimumCount: 4)
            .compactMap(normalizeContractFlowEvent)

        #expect(normalized.contains(.pathChanged))
        #expect(normalized.contains(.intentRejected(.pushBlockedByModalTail)))
        #expect(normalized.contains(.modalDismissed))
        #expect(normalized.contains(.modalQueueChanged))
        #expect(normalized.contains(.modalPresented))
    }

    @Test("Flow deep-link pending slot supports replace, clear, and guarded resume")
    @MainActor
    func flowDeepLinkPendingSlotContract() async {
        let isAuthenticated = Mutex(false)
        let matcher = FlowDeepLinkMatcher<ContractRoute> {
            FlowDeepLinkMapping("/secure") { _ in
                FlowPlan(steps: [.push(.secure)])
            }
            FlowDeepLinkMapping("/home/secure") { _ in
                FlowPlan(steps: [.push(.home), .push(.secure)])
            }
        }
        let pipeline = FlowDeepLinkPipeline<ContractRoute>(
            allowedSchemes: ["myapp"],
            allowedHosts: ["app"],
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    route == .secure
                },
                isAuthenticated: {
                    isAuthenticated.withLock { $0 }
                }
            )
        )
        let store = FlowStore<ContractRoute>()
        let handler = FlowDeepLinkEffectHandler<ContractRoute>(
            pipeline: pipeline,
            applier: store
        )

        let firstURL = URL(string: "myapp://app/secure")!
        let secondURL = URL(string: "myapp://app/home/secure")!

        let firstResult = handler.handle(firstURL)
        guard case .pending(let firstPending) = firstResult else {
            Issue.record("Expected first handle to defer, got \(firstResult)")
            return
        }
        #expect(firstPending.plan.steps == [.push(.secure)])
        #expect(handler.pendingDeepLink == firstPending)

        let secondResult = handler.handle(secondURL)
        guard case .pending(let replacedPending) = secondResult else {
            Issue.record("Expected second handle to replace the pending slot, got \(secondResult)")
            return
        }
        #expect(replacedPending.plan.steps == [.push(.home), .push(.secure)])
        #expect(handler.pendingDeepLink == replacedPending)

        let denied = await handler.resumePendingDeepLinkIfAllowed { _ in false }
        #expect(denied == .pending(replacedPending))
        #expect(handler.pendingDeepLink == replacedPending)

        handler.clearPendingDeepLink()
        #expect(handler.pendingDeepLink == nil)
        #expect(handler.resumePendingDeepLink() == .noPendingDeepLink)

        guard case .pending(let resumedPending) = handler.handle(firstURL) else {
            Issue.record("Expected to restore a pending slot after clear")
            return
        }
        isAuthenticated.withLock { $0 = true }

        let resumed = handler.resumePendingDeepLink()
        if case .executed(let plan, let path) = resumed {
            #expect(plan == resumedPending.plan)
            #expect(path == [.push(.secure)])
        } else {
            Issue.record("Expected pending replay to execute after auth, got \(resumed)")
        }
        #expect(!handler.hasPendingDeepLink)
        #expect(store.path == [.push(.secure)])
    }
}
