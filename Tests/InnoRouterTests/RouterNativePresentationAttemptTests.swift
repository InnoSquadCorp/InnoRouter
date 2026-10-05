import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Native presentation attempt arbitration")
@MainActor
struct RouterNativePresentationAttemptTests {
    private enum R: Route { case root }
    private func handle(_ store: RouterStore<R>) async throws -> RouterPresentationHandle {
        _ = await store.perform(.presentAlert(.init(content: .init(title: "T", actions: [.init(id: "a", label: "A")]))))
        return try #require(store.presentationHandle())
    }

    @Test("Selection wins over a provisional binding dismissal in either order", arguments: [false, true])
    func selectionBeforeSettlement(bindingFirst: Bool) async throws {
        let store = RouterStore<R>(), captured = try await handle(store)
        let attempt = RouterNativePresentationAttempt(handle: captured)
        if bindingFirst { attempt.nativeDismissalObserved() }
        attempt.select("a")
        attempt.nativeDismissalObserved()
        attempt.select("duplicate")
        #expect(attempt.settle() == .select("a", captured))
        attempt.nativeDismissalObserved()
        attempt.select("late")
        #expect(attempt.settle() == nil)
    }

    @Test("A genuine dismissal requires explicit settlement and submits once")
    func dismissal() async throws {
        let store = RouterStore<R>(), captured = try await handle(store)
        let attempt = RouterNativePresentationAttempt(handle: captured)
        #expect(attempt.settle() == nil)
        attempt.nativeDismissalObserved()
        attempt.nativeDismissalObserved()
        #expect(attempt.settle() == .dismiss(captured))
        attempt.select("late")
        #expect(attempt.settle() == nil)
    }

    @Test("Retirement cancels all pending and late callback authority", arguments: [false, true])
    func retirement(selected: Bool) async throws {
        let store = RouterStore<R>(), captured = try await handle(store)
        let attempt = RouterNativePresentationAttempt(handle: captured)
        if selected { attempt.select("a") } else { attempt.nativeDismissalObserved() }
        attempt.retire()
        attempt.nativeDismissalObserved()
        attempt.select("late")
        #expect(attempt.settle() == nil)
    }

    @Test("A fresh presenter never revives a retired attempt or refreshes its captured handle")
    func reconciliation() async throws {
        let store = RouterStore<R>(), captured = try await handle(store)
        let old = RouterNativePresentationAttempt(handle: captured)
        old.select("a")
        #expect(old.settle() == .select("a", captured))
        let fresh = RouterNativePresentationAttempt(handle: captured)
        #expect(fresh.id != old.id)
        old.nativeDismissalObserved()
        #expect(old.settle() == nil)
        _ = await store.replaceSubtree(with: store.state.root)
        fresh.select("a")
        guard case .select(let action, let original)? = fresh.settle() else { Issue.record("Missing captured command"); return }
        #expect(original == captured)
        guard case .rejected(_, _, _, .mutation(.expiredPresentation)) = await store.selectPresentationAction(action, using: original) else {
            Issue.record("An attempt silently acquired replacement authority"); return
        }
    }
}
