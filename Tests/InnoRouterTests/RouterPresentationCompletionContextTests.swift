import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Presentation completion authority is not context metadata", .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationCompletionContextTests {
    private enum R: Route { case child }

    @Test("Public resumedDeferral metadata cannot release a privately held result")
    func forgedCompletionContext() async throws {
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold-result") { transition in
                if case .dismissPresentation = transition.action, transition.context.resumedDeferral == nil {
                    return .deferRequest(id)
                }
                return .allow
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await store.present(.child, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        do { try await store.finishPresentation(returning: "held-result"); Issue.record("Expected deferral") }
        catch { #expect(error as? RouterPresentationCompletionError == .dismissalDeferred(id)) }
        // Context remains app-visible metadata. This app policy allows the
        // direct dismissal, but metadata alone must not own the held value.
        _ = await store.perform(.dismissPresentation, context: .init(resumedDeferral: id))
        #expect(await result.value == .dismissed)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.state == .rootStack)
        _ = await store.cancelDeferred(id)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("The real deferral resolver retains ownership of its prepared value")
    func trustedCompletionContext() async throws {
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold-result") { transition in
                if case .dismissPresentation = transition.action, transition.context.resumedDeferral == nil {
                    return .deferRequest(id)
                }
                return .allow
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in await store.present(.child, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        do { try await store.finishPresentation(returning: "held-result"); Issue.record("Expected deferral") }
        catch { #expect(error as? RouterPresentationCompletionError == .dismissalDeferred(id)) }
        _ = await store.resumeDeferred(id)
        #expect(await result.value == .value("held-result"))
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.deferredTransitions.isEmpty)
    }
}
