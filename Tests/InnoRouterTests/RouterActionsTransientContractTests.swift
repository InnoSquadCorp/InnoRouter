import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Environment action facade transient contracts", .timeLimit(.minutes(1)))
@MainActor
struct RouterActionsTransientContractTests {
    private enum R: Route { case root }

    @Test("The real action facade awaits the same Store result authority")
    func facadeSelection() async throws {
        let store = RouterStore<R>()
        let actions = RouterActions(authority: .init(scope: store.scope()))
        let reader = RouterStateReader(scope: store.scope())
        var events = store.events.makeAsyncIterator()
        let task = Task { @MainActor in
            await actions.present(RouterTransientPresentationRequest<Int>.alert(title: "T", actions: [.init(id: "a", label: "A", value: 42)]))
        }
        defer { task.cancel() }
        while let event = await events.next() { if case .committed = event { break } }
        #expect(reader.presentation == nil)
        #expect(reader.presentationFamily?.kind == .alert)
        #expect(reader.canDismissPresentation)
        let handle = try #require(store.presentationHandle())
        _ = await actions.perform(.selectPresentationAction(presentationID: handle.id, actionID: "a"))
        #expect(await task.value == .value(42))
        #expect(!reader.canDismissPresentation)
    }

    @Test("A missing action facade rejects without creating result authority")
    func missingFacade() async {
        let actions = RouterActions(routeType: R.self, environmentMissingPolicy: .logAndDegrade, environment: nil)
        let result = await actions.present(RouterTransientPresentationRequest<Int>.confirmationDialog(title: "T", actions: [.init(id: "a", label: "A", value: 1)]))
        guard case .rejected(.missingAuthority) = result else { Issue.record("Expected missing authority"); return }
    }
}
