import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Native transient captured authority")
@MainActor
struct RouterNativeTransientCaptureTests {
    private enum R: Route { case root }

    @Test("Native metadata observes both transient families and excludes navigation", arguments: [false, true])
    func captureMetadata(dialog: Bool) async throws {
        let store = RouterStore<R>()
        let scope = store.scope()
        #expect(RouterTransientPresentationCapture(owner: scope) == nil)
        let value = RouterTransientPresentation(content: .init(title: "Title", message: "Message", actions: [
            .init(id: "cancel", label: "Cancel", role: .cancel),
        ]))
        _ = await store.perform(dialog ? .presentConfirmationDialog(value) : .presentAlert(value))
        let capture = try #require(RouterTransientPresentationCapture(owner: scope))
        #expect(capture.kind == (dialog ? .confirmationDialog : .alert))
        #expect(capture.content == value.content)
        #expect(capture.isCurrent())
        await capture.submit(.select("cancel", capture.handle))
        #expect(!capture.isCurrent())
        #expect(store.state == .rootStack)
        _ = await store.perform(.present(.init(route: .root, style: .sheet)))
        #expect(RouterTransientPresentationCapture(owner: scope) == nil)
    }

    @Test("A late native selection cannot borrow a same-ID replacement's authority", arguments: [false, true])
    func sameIDReplacement(dismiss: Bool) async throws {
        let store = RouterStore<R>()
        let scope = store.scope()
        _ = await store.perform(.presentAlert(.init(content: .init(title: "Title", actions: [.init(id: "ok", label: "OK")]))))
        let old = try #require(RouterTransientPresentationCapture(owner: scope))
        _ = await store.replaceSubtree(with: store.state.root)
        let current = try #require(RouterTransientPresentationCapture(owner: store.scope()))
        let revision = store.revision
        #expect(old.handle.id == current.handle.id)
        #expect(old.handle != current.handle)
        #expect(!old.isCurrent())
        #expect(current.isCurrent())
        await old.submit(dismiss ? .dismiss(old.handle) : .select("ok", old.handle))
        #expect(store.revision == revision)
        #expect(current.isCurrent())
        await current.submit(.select("ok", current.handle))
        #expect(store.revision == revision + 1)
        #expect(store.state == .rootStack)
    }

    @Test("Rejected native selection keeps canonical state and can use a fresh attempt")
    func rejectedSelection() async throws {
        var shouldReject = true
        let store = try RouterStore<R>(configuration: .init(policies: [.init(name: "native-selection") { transition in
            if shouldReject, case .selectPresentationAction = transition.action { return .reject("blocked") }
            return .allow
        }]))
        _ = await store.perform(.presentAlert(.init(content: .init(title: "Title", actions: [.init(id: "ok", label: "OK")]))))
        let capture = try #require(RouterTransientPresentationCapture(owner: store.scope()))
        let old = RouterNativePresentationAttempt(handle: capture.handle)
        old.select("ok")
        let command = try #require(old.settle())
        let revision = store.revision
        await capture.submit(command)
        #expect(store.revision == revision)
        #expect(capture.isCurrent())
        old.retire()
        #expect(old.settle() == nil)
        shouldReject = false
        let fresh = RouterNativePresentationAttempt(handle: capture.handle)
        fresh.select("ok")
        await capture.submit(try #require(fresh.settle()))
        #expect(store.revision == revision + 1)
        #expect(!capture.isCurrent())
    }
}
