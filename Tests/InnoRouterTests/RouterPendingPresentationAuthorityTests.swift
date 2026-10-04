import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Pending presentation authority admission", .timeLimit(.minutes(1)))
@MainActor
struct RouterPendingPresentationAuthorityTests {
    private enum R: Route { case child }

    @Test("Only the original deferred show can activate its reserved typed waiter", arguments: [false, true])
    func reservedShowID(navigation: Bool) async throws {
        let deferral = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold-show") { transition in
                guard transition.context.resumedDeferral == nil else { return .allow }
                switch transition.action {
                case .present, .presentAlert: return .deferRequest(deferral)
                default: return .allow
                }
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let request = RouterTransientPresentationRequest<String>.alert(title: "Original", actions: [
            .init(id: "accept", label: "Accept", value: "original-value"),
        ])
        let result = Task { @MainActor in
            if navigation { return await store.present(.child, expecting: String.self) }
            return await store.present(request)
        }
        defer { result.cancel() }
        while let event = await events.next() { if case .deferred = event { break } }
        let id = try #require(store.presentationWaiters.keys.first)
        #expect(store.presentationWaiters[id]?.activatedToken() == nil)
        let impostor = RouterTransientPresentation(id: id, content: .init(title: "Impostor", actions: [
            .init(id: "accept", label: "Accept"),
        ]))
        let attempts: [RouterAction<R>] = [
            .presentConfirmationDialog(impostor),
            .apply(.init(state: try .init(root: .stack(presentationFamily: .alert(impostor))))),
        ]
        for action in attempts {
            guard case .rejected(_, _, _, .mutation(.presentationIdentityConflict(id))) = await store.perform(action) else {
                Issue.record("Unrelated request acquired the pending show ID"); continue
            }
            #expect(store.state == .rootStack)
            #expect(store.revision == 0)
            #expect(store.presentationWaiters[id]?.activatedToken() == nil)
        }
        _ = await store.resumeDeferred(deferral)
        #expect(store.presentationWaiters[id]?.activatedToken() != nil)
        if navigation { try await store.finishPresentation(returning: "original-value") }
        else { _ = await store.perform(.selectPresentationAction(presentationID: id, actionID: "accept")) }
        #expect(await result.value == .value("original-value"))
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("Oversized scope input is rejected before authorization generation or waiter creation", arguments: [false, true])
    func earlyScopeAdmission(navigation: Bool) async throws {
        let generations = Mutex(0)
        let store = try RouterStore<R>(configuration: .init(
            resourceBudget: .init(snapshot: .init(maximumGraphDepth: 2)),
            authorization: .init(generation: { generations.withLock { $0 += 1 }; return 0 },
                                 requiresAuthorization: { _ in false }, authorize: { true })
        ))
        generations.withLock { $0 = 0 }
        let path = RouterScopePath.root.appending("a").appending("b")
        let outcome: RouterPresentationOutcome<String>
        if navigation { outcome = await store.present(.child, at: path, expecting: String.self) }
        else { outcome = await store.present(.alert(title: "T", actions: [.init(id: "a", label: "A", value: "v")]), at: path) }
        guard case .rejected(.resourceLimit) = outcome else { Issue.record("Expected bounded scope rejection"); return }
        #expect(generations.withLock { $0 } == 0)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.presentationRequestIDs.isEmpty)
        #expect(store.revision == 0)
    }
}
