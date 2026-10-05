import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Presentation terminal ownership", .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationTerminalOwnershipTests {
    private enum R: Route { case parent, child }

    @Test("Direct parent completion cancels descendants without cross-delivering values", arguments: [false, true])
    func parentCompletion(returnsValue: Bool) async throws {
        let store = RouterStore<R>()
        var events = store.events.makeAsyncIterator()
        let parent = Task { @MainActor in await store.present(.parent, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        guard case .stack(let stack) = store.state.root else { parent.cancel(); Issue.record("Missing stack"); return }
        let id = try #require(stack.presentation?.id)
        let scope = store.scope(at: .root.appendingPresentation(id))
        let child = Task { @MainActor in await scope.present(.child, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        #expect(store.presentationWaiters.count == 2)
        if returnsValue { try await store.finishPresentation(returning: "parent-value") }
        else { _ = await store.perform(.dismissPresentation) }
        #expect(await parent.value == (returnsValue ? .value("parent-value") : .dismissed))
        #expect(await child.value == .cancelled)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.state == .rootStack)
        #expect(store.revision == 3)
    }

    @Test("Committed child value is retained when its parent is later dismissed")
    func childCompletionFirst() async throws {
        let store = RouterStore<R>()
        var events = store.events.makeAsyncIterator()
        let parent = Task { @MainActor in await store.present(.parent, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        guard case .stack(let stack) = store.state.root else { parent.cancel(); Issue.record("Missing stack"); return }
        let id = try #require(stack.presentation?.id)
        let scope = store.scope(at: .root.appendingPresentation(id))
        let child = Task { @MainActor in await scope.present(.child, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        try await scope.finishPresentation(returning: "child-value")
        #expect(await child.value == .value("child-value"))
        #expect(store.presentationWaiters.count == 1)
        _ = await store.perform(.dismissPresentation)
        #expect(await parent.value == .dismissed)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.revision == 4)
    }

    @Test("Rejected and deferred parent dismissal retain both waiters until commit")
    func parentPolicyRetainsOwnership() async throws {
        let deferral = RouterDeferralID()
        let deny = Mutex(true)
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "parent-dismiss") { transition in
                guard case .dismissPresentation = transition.action else { return .allow }
                if deny.withLock({ $0 }) { return .reject("denied") }
                return transition.context.resumedDeferral == nil ? .deferRequest(deferral) : .allow
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let parent = Task { @MainActor in await store.present(.parent, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        guard case .stack(let stack) = store.state.root else { parent.cancel(); Issue.record("Missing stack"); return }
        let id = try #require(stack.presentation?.id)
        let scope = store.scope(at: .root.appendingPresentation(id))
        let child = Task { @MainActor in await scope.present(.child, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        let original = store.state
        guard case .rejected = await store.perform(.dismissPresentation) else { Issue.record("Expected rejection"); return }
        #expect(store.state == original)
        #expect(store.revision == 2)
        #expect(store.presentationWaiters.count == 2)
        deny.withLock { $0 = false }
        guard case .deferred = await store.perform(.dismissPresentation) else { Issue.record("Expected deferral"); return }
        #expect(store.state == original)
        #expect(store.revision == 2)
        #expect(store.presentationWaiters.count == 2)
        _ = await store.resumeDeferred(deferral)
        #expect(await parent.value == .dismissed)
        #expect(await child.value == .cancelled)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.revision == 3)
    }
}
