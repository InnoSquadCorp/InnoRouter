import Foundation
import SwiftUI
import Testing
import InnoRouter
import InnoRouterTesting
import RouterSkillExample

@Suite("Router skill release consumer", .timeLimit(.minutes(1)))
@MainActor
struct ConsumerTests {
    @Test func macroAndOriginContract() throws {
        let accepted = try #require(URL(string: "routerskill://router.example.com/products/42"))
        let foreign = try #require(URL(string: "routerskill://foreign.example.com/products/42"))
        let wrongScheme = try #require(URL(string: "other://router.example.com/products/42"))
        #expect(AppRoute.resolveDeepLink(accepted) == .product(id: "42"))
        #expect(AppRoute.resolveDeepLink(foreign) == nil)
        #expect(AppRoute.resolveDeepLink(wrongScheme) == nil)
        #expect(AppRoute.Tab.settings.routerScopeID == "settings")
        let request: RouterPresentationRequest<AppRoute, Bool> = AppRoute.Presentation.confirmation
        #expect(request.route == .confirmation)
    }

    @Test func exhaustiveNavigation() async {
        let test = RouterTestStore<AppRoute>()
        _ = await test.send(.push(.product(id: "42")))
        test.receiveStarted()
        test.receiveCommitted { $0 == .rootStack(path: [.product(id: "42")]) && $1 == 1 }
        _ = await test.send(.pop(count: 1))
        test.receiveStarted()
        test.receiveCommitted { $0 == .rootStack && $1 == 2 }
        await test.finish()
    }

    @Test func draftIsolationAndAdmission() throws {
        let original = RouterState<AppRoute>.rootStack
        var draft = RouterStateDraft(original)
        draft.root = .stack(path: [.home, .settings])
        let small = RouterResourceBudget(snapshot: try .init(maximumRoutes: 1))
        #expect(throws: RouterResourceLimitFailure.self) { try draft.build(resourceBudget: small) }
        #expect(original == .rootStack)
        #expect(try draft.build() == .rootStack(path: [.home, .settings]))
    }

    @Test func invalidConfigurationThrows() throws {
        #expect(throws: (any Error).self) {
            try AppRoute.makeRouterStore(configuration: .init(
                resourceBudget: .init(maximumPendingRequests: -1)
            ))
        }
        let store = try makeConfiguredStore()
        let host = RouterHost(store: store) { Text("Home") }
        #expect(host.validationFailure == nil)
        #expect(store.revision == 0)
    }

    @Test func swiftUISetupCompiles() throws {
        _ = StackRoot()
        _ = TabsRoot()
        _ = try RouterTabHost(AppRoute.self, initial: .home)
    }

    @Test func hostReplacementIsExplicit() async throws {
        let store = try makeConfiguredStore()
        let tabs = try RouterStateDraft<AppRoute>(root: .container(.init(
            style: .tabs, selection: "left", branches: [.init(id: "left"), .init(id: "right")]
        ))).build()
        guard case .rejected = await store.perform(.apply(.init(state: tabs))) else {
            Issue.record("Ordinary apply cannot change the configured host"); return
        }
        #expect(store.state == .rootStack && store.revision == 0)
        let descriptor = RouterHostDescriptor<AppRoute>(root: .tabs(branches: [
            .init("left", shape: .stack), .init("right", shape: .stack),
        ], extras: .reject))
        guard case .applied = await store.replaceHost(with: .init(state: tabs), descriptor: descriptor) else {
            Issue.record("Explicit matching replacement must apply"); return
        }
        #expect(store.state == tabs && store.revision == 1)
    }

    @Test func replacedScopeExpiresButSiblingSurvives() async throws {
        let state = try RouterStateDraft<AppRoute>(root: .container(.init(
            style: .tabs, selection: "left", branches: [.init(id: "left"), .init(id: "right")]
        ))).build()
        let store = try RouterStore(initialState: state)
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        _ = await store.replaceSubtree(at: ["left"], with: .stack())
        #expect(left.node == nil)
        guard case .rejected = await left.perform(.push(.home)) else {
            Issue.record("Retired scope must reject execution"); return
        }
        guard case .applied = await right.perform(.push(.settings)) else {
            Issue.record("Unaffected sibling must still execute"); return
        }
        #expect(store.state.node(at: ["right"]) == .stack(path: [.settings]))
    }

    @Test func snapshotRoundTrip() async throws {
        let store = AppRoute.makeRouterStore()
        _ = await store.perform(.push(.product(id: "saved")))
        let codec = try RouterSnapshotCodec<AppRoute>(currentVersion: 1)
        let data = try await store.snapshot(using: codec)
        let target = AppRoute.makeRouterStore()
        _ = try await target.restore(from: data, using: codec)
        #expect(target.state == store.state)
        #expect(target.revision == 1)
    }

    @Test func cancelRoleReturnsItsValue() async throws {
        let store = AppRoute.makeRouterStore()
        var events = store.events.makeAsyncIterator()
        let task = Task { await store.present(removalRequest()) }
        defer { task.cancel() }
        while let event = await events.next() { if case .committed = event { break } }
        let handle = try #require(store.presentationHandle())
        _ = await store.selectPresentationAction("keep", using: handle)
        #expect(await task.value == .value(false))
    }

    @Test func callerCancellationRetiresWaiter() async throws {
        let store = AppRoute.makeRouterStore()
        var events = store.events.makeAsyncIterator()
        let task = Task { await store.present(removalRequest()) }
        defer { task.cancel() }
        while let event = await events.next() { if case .committed = event { break } }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(store.presentationHandle() == nil)
    }

    @Test func transientSnapshotOmissionPreservesLiveState() async throws {
        let store = AppRoute.makeRouterStore()
        var events = store.events.makeAsyncIterator()
        let task = Task { await store.present(removalRequest()) }
        defer { task.cancel() }
        while let event = await events.next() { if case .committed = event { break } }
        let original = store.state
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<AppRoute>(currentVersion: 1).encode(original)
        }
        let codec = try RouterSnapshotCodec<AppRoute>(currentVersion: 1, transientPresentations: .omit)
        let data = try codec.encode(original)
        let restored = AppRoute.makeRouterStore()
        _ = try await restored.restore(from: data, using: codec)
        #expect(restored.state == .rootStack)
        #expect(store.state == original)
        let handle = try #require(store.presentationHandle())
        _ = await store.dismissPresentation(using: handle)
        #expect(await task.value == .dismissed)
    }
}
