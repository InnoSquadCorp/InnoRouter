// MARK: - RouterTwelfthReviewRegressionTests.swift
import Foundation
import Testing
import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

private enum ProbeChild: Route { case home, detail }
private enum ProbeParent: Route { case feature(ProbeChild), sibling }
enum InvalidFeaturePlanScenes: Equatable, Sendable {
    case window, immersiveSpace, both
}
private extension RouterOutcome {
    var probeRejection: RouterRejectionReason? {
        guard case .rejected(_, _, _, let reason) = self else { return nil }
        return reason
    }
}
private let probeMapping = RouterFeatureMapping<ProbeParent, ProbeChild>(
    id: "feature", namespace: "ProbeParent.feature",
    route: .init(embed: ProbeParent.feature, extract: {
        guard case .feature(let route) = $0 else { return nil }
        return route
    })
)

@MainActor
private final class OneShotDeferrer {
    private var didDefer = false

    func decide(_ id: RouterDeferralID) -> RouterPolicyDecision {
        guard !didDefer else { return .allow }
        didDefer = true
        return .deferRequest(id)
    }
}

@Suite @MainActor
struct RouterTwelfthReviewRegressionTests {
    @Test(arguments: [
        InvalidFeaturePlanScenes.window,
        .immersiveSpace,
        .both,
    ])
    func featurePlanWithScenesMustReject(_ scenes: InvalidFeaturePlanScenes) async throws {
        let store = RouterStore<ProbeParent>(initialState: .rootStack(path: [.feature(.home)]))
        let feature = RouterFeatureScope(parent: store.scope(), mapping: probeMapping)
        let windows: [RouterWindow<ProbeChild>] = scenes == .immersiveSpace
            ? []
            : [.init(route: .home)]
        let immersiveSpace: RouterImmersiveSpace<ProbeChild>? = scenes == .window
            ? nil
            : .init(id: "feature-space", route: .home)
        let invalid = try RouterState<ProbeChild>(
            root: .stack(path: [.detail]),
            windows: windows,
            immersiveSpace: immersiveSpace
        )
        let outcome = await feature.perform(.apply(.init(state: invalid)))
        #expect(outcome.probeRejection == .featureProjection(.globalStateNotAllowed(namespace: "ProbeParent.feature")))
        #expect(store.revision == 0)
        #expect(store.state.root == .stack(path: [.feature(.home)]))
    }

    @Test func deferredFeatureMustNotEnterReplacementImmersiveLifetime() async throws {
        let deferredID = RouterDeferralID()
        let initial = try RouterState<ProbeParent>(immersiveSpace: .init(
            id: "shared", route: .feature(.home), node: .stack(path: [.feature(.home)])
        ))
        let store = RouterStore(initialState: initial, configuration: .init(policies: [
            RouterPolicy(name: "defer-plan") { transition in
                if case .apply = transition.action, transition.context.resumedDeferral == nil {
                    return .deferRequest(deferredID)
                }
                return .allow
            }
        ]))
        let feature = RouterFeatureScope(parent: store.scope(at: .immersiveSpace("shared")), mapping: probeMapping)
        guard case .deferred = await feature.perform(.apply(.init(state: .rootStack(path: [.detail])))) else {
            Issue.record("Expected deferral"); return
        }
        let oldToken = store.immersiveSpaceLifecycleToken
        _ = await store.perform(.dismissImmersiveSpace)
        _ = await store.perform(.enterImmersiveSpace(.init(
            id: "shared", route: .feature(.home), node: .stack(path: [.feature(.home)])
        )))
        #expect(store.immersiveSpaceLifecycleToken != oldToken)
        let outcome = await store.resolveDeferred(deferredID, with: .allow, resumeStrategy: .rebaseOnCurrentState)
        #expect(outcome.probeRejection != nil)
        #expect(store.revision == 2)
        #expect(store.state.immersiveSpace?.node == .stack(path: [.feature(.home)]))
    }

    @Test func deferredWindowFeatureActionMustNotEnterReusedWindowID() async throws {
        let windowID = UUID()
        let deferredID = RouterDeferralID()
        let initial = try RouterState<ProbeParent>(windows: [.init(
            id: windowID,
            route: .feature(.home),
            node: .stack(path: [.feature(.home)])
        )])
        let deferrer = OneShotDeferrer()
        let store = RouterStore(initialState: initial, configuration: .init(policies: [
            RouterPolicy(name: "defer-once") { _ in deferrer.decide(deferredID) }
        ]))
        let feature = RouterFeatureScope(
            parent: store.scope(at: .window(windowID)),
            mapping: probeMapping
        )
        guard case .deferred = await feature.perform(.push(.detail)) else {
            Issue.record("Expected deferral")
            return
        }
        let oldToken = store.windowLifecycleTokens[windowID]
        _ = await store.perform(.dismissWindow(windowID))
        _ = await store.perform(.openWindow(.init(
            id: windowID,
            route: .feature(.home),
            node: .stack(path: [.feature(.home)])
        )))
        #expect(store.windowLifecycleTokens[windowID] != oldToken)

        let outcome = await store.resolveDeferred(
            deferredID,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        )
        #expect(outcome.probeRejection != nil)
        #expect(store.revision == 2)
        #expect(store.state.node(at: .window(windowID)) == .stack(path: [.feature(.home)]))
    }

    @Test func missingWindowScopeMustNotAcquireAWindowOpenedWhileQueued() async throws {
        let windowID = UUID()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let store = RouterStore<ProbeParent>(
            initialState: .rootStack,
            configuration: .init(policies: [
                RouterPolicy(name: "hold-open") { transition in
                    guard case .openWindow = transition.action else { return .allow }
                    for await _ in gate { break }
                    return .allow
                },
            ])
        )
        let missingScope = store.scope(at: .window(windowID))
        var events = store.events.makeAsyncIterator()
        let open = Task { @MainActor in
            await store.perform(.openWindow(.init(
                id: windowID,
                route: .sibling,
                node: .stack(path: [.sibling])
            )))
        }
        guard case .started = await events.next() else {
            release.finish()
            Issue.record("Expected the window open to own the active lane")
            return
        }
        let staleAction = Task { @MainActor in
            await missingScope.perform(.push(.feature(.home)))
        }
        release.finish()
        guard case .applied = await open.value else {
            Issue.record("Expected the window to open")
            return
        }
        guard case .rejected(_, _, _, .mutation(.windowNotFound(let rejectedID))) =
            await staleAction.value else {
            Issue.record("Expected the missing scope to remain expired")
            return
        }
        #expect(rejectedID == windowID)
        #expect(store.revision == 1)
        #expect(store.state.node(at: .window(windowID)) == .stack(path: [.sibling]))
    }

    @Test func sameWindowLifetimeFeatureRebasePreservesUnrelatedRootChange() async throws {
        let windowID = UUID()
        let deferredID = RouterDeferralID()
        let initial = try RouterState<ProbeParent>(windows: [.init(
            id: windowID,
            route: .feature(.home),
            node: .stack(path: [.feature(.home)])
        )])
        let deferrer = OneShotDeferrer()
        let store = RouterStore(initialState: initial, configuration: .init(policies: [
            RouterPolicy(name: "defer-once") { _ in deferrer.decide(deferredID) }
        ]))
        let feature = RouterFeatureScope(
            parent: store.scope(at: .window(windowID)),
            mapping: probeMapping
        )
        guard case .deferred = await feature.perform(.push(.detail)) else {
            Issue.record("Expected deferral")
            return
        }
        let token = store.windowLifecycleTokens[windowID]
        _ = await store.perform(.push(.sibling))
        let outcome = await store.resolveDeferred(
            deferredID,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        )
        guard case .applied = outcome else {
            Issue.record("Expected same-lifetime rebase")
            return
        }
        #expect(store.windowLifecycleTokens[windowID] == token)
        #expect(store.state.root == .stack(path: [.sibling]))
        #expect(
            store.state.node(at: .window(windowID))
                == .stack(path: [.feature(.home), .feature(.detail)])
        )
    }

    @Test(arguments: [0, 1, 2])
    func failedImmersiveRestorationMustSurviveFullQueue(limit: Int) async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let initial = try RouterState<ProbeParent>(immersiveSpace: .init(id: "shared", route: .sibling))
        let store = RouterStore(initialState: initial, configuration: .init(
            policies: [RouterPolicy(name: "hold") { _ in
                for await _ in gate { break }
                return .allow
            }], maximumPendingRequestCount: limit
        ))
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        var events = store.events.makeAsyncIterator()
        let active = Task { @MainActor in await store.perform(.push(.sibling)) }
        guard case .started = await events.next() else {
            release.finish(); Issue.record("Expected active request"); return
        }
        var requests = store.requestObservations.makeAsyncIterator()
        var queued: [Task<RouterOutcome<ProbeParent>, Never>] = []
        for _ in 0 ..< limit {
            queued.append(Task { @MainActor in
                await store.perform(.push(.feature(.home)))
            })
            _ = await requests.next()
        }
        let restore = Task { @MainActor in
            await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store) { .error }
        }
        _ = await requests.next()
        release.finish()
        _ = await restore.value
        _ = await active.value
        for task in queued { _ = await task.value }
        #expect(store.state.immersiveSpace == nil)
    }

    @Test func featureCompletionDeferralMustRetainOwnershipPrecondition() async throws {
        let deferredID = RouterDeferralID()
        let store = RouterStore<ProbeParent>(
            initialState: .rootStack(path: [.feature(.home)]),
            configuration: .init(policies: [
                RouterPolicy(name: "defer-completion") { transition in
                    guard transition.context.resumedDeferral == nil,
                          case .dismissPresentation = transition.action else {
                        return .allow
                    }
                    return .deferRequest(deferredID)
                },
            ])
        )
        let feature = RouterFeatureScope(parent: store.scope(), mapping: probeMapping)
        var events = store.events.makeAsyncIterator()
        let presented = Task { @MainActor in
            await feature.present(.detail, expecting: String.self)
        }
        while let event = await events.next() {
            if case .committed = event { break }
        }
        await #expect(throws: RouterPresentationCompletionError.self) {
            try await feature.finishPresentation(returning: "stale-value")
        }
        guard case .stack(let root) = store.state.root else {
            presented.cancel()
            Issue.record("Expected a root stack")
            return
        }
        var replacement = store.state
        replacement.root = .stack(path: [.sibling], presentation: root.presentation)
        guard case .applied = await store.perform(.apply(.init(state: replacement))) else {
            presented.cancel()
            Issue.record("Expected the feature owner to be replaced without dismissing its presentation")
            return
        }
        guard case .rejected(_, _, _, .featureProjection) = await store.resolveDeferred(
            deferredID,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected the resumed completion to reject its replaced owner")
            presented.cancel()
            return
        }
        #expect(store.revision == 2)
        presented.cancel()
        #expect(await presented.value != .value("stale-value"))
    }

    @Test func featurePendingLinkAndSystemRepairRemainIndependent() async throws {
        let featureDeferral = RouterDeferralID()
        let linkDeferral = RouterDeferralID()
        let initial = try RouterState<ProbeParent>(
            root: .stack(path: [.feature(.home)]),
            immersiveSpace: .init(id: "shared", route: .sibling)
        )
        let store = RouterStore(initialState: initial, configuration: .init(policies: [
            RouterPolicy(name: "separate-families") { transition in
                guard transition.context.resumedDeferral == nil,
                      case .apply = transition.action else { return .allow }
                return transition.context.source == .deepLink
                    ? .deferRequest(linkDeferral)
                    : .deferRequest(featureDeferral)
            },
        ]))
        let feature = RouterFeatureScope(parent: store.scope(), mapping: probeMapping)
        let link = PendingRouterLink<ProbeParent>(
            url: try #require(URL(string: "innorouter://app/competing-request")),
            gatedRoute: .sibling,
            plan: .init(state: .rootStack(path: [.sibling]))
        )
        let slot = RouterPendingLinkSlot(link)

        guard case .deferred = await feature.perform(
            .apply(.init(state: .rootStack(path: [.detail])))
        ), case .completed(_, .deferred) = await slot.resume(on: store) else {
            Issue.record("Expected independent feature and pending-link deferrals")
            return
        }
        #expect(slot.cancel() == link)
        guard case .applied = await store.reconcileSceneSystemFailure(
            .dismissImmersiveSpace
        ) else {
            Issue.record("Expected native repair to use the Store lane")
            return
        }
        guard case .applied = await store.resolveDeferred(
            featureDeferral,
            with: .allow,
            resumeStrategy: .rebaseOnCurrentState
        ) else {
            Issue.record("Expected link cancellation and repair to preserve feature ownership")
            return
        }
        #expect(store.state.root == .stack(path: [.feature(.detail)]))
        #expect(store.state.immersiveSpace == nil)
        #expect(store.revision == 2)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test func systemRepairBypassesRejectWhileBusyWithoutInterruptingActiveRequest() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let initial = try RouterState<ProbeParent>(immersiveSpace: .init(
            id: "shared",
            route: .sibling
        ))
        let store = RouterStore(initialState: initial, configuration: .init(
            policies: [RouterPolicy(name: "hold") { _ in
                for await _ in gate { break }
                return .allow
            }],
            schedulingPolicy: .rejectWhileBusy,
            maximumPendingRequestCount: 0,
            requestOverflowStrategy: .discardOldest
        ))
        var events = store.events.makeAsyncIterator()
        let active = Task { @MainActor in await store.perform(.push(.sibling)) }
        guard case .started = await events.next() else {
            release.finish()
            Issue.record("Expected active request")
            return
        }
        let repair = Task { @MainActor in
            await store.reconcileSceneSystemFailure(.dismissImmersiveSpace)
        }
        release.finish()
        guard case .applied = await active.value else {
            Issue.record("Expected active request to finish")
            return
        }
        guard case .applied = await repair.value else {
            Issue.record("Expected repair to receive the next Store lane")
            return
        }
        #expect(store.state.root == .stack(path: [.sibling]))
        #expect(store.state.immersiveSpace == nil)
    }

    @Test func duplicateSystemRepairIsCoalescedBySceneLifetime() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let initial = try RouterState<ProbeParent>(immersiveSpace: .init(
            id: "shared",
            route: .sibling
        ))
        let store = RouterStore(initialState: initial, configuration: .init(
            policies: [RouterPolicy(name: "hold") { _ in
                for await _ in gate { break }
                return .allow
            }]
        ))
        var events = store.events.makeAsyncIterator()
        let active = Task { @MainActor in await store.perform(.push(.sibling)) }
        guard case .started = await events.next() else {
            release.finish()
            Issue.record("Expected active request")
            return
        }
        var requests = store.requestObservations.makeAsyncIterator()
        let first = Task { @MainActor in
            await store.reconcileSceneSystemFailure(.dismissImmersiveSpace)
        }
        _ = await requests.next()
        let duplicate = await store.reconcileSceneSystemFailure(.dismissImmersiveSpace)
        guard case .rejected(_, _, _, .coalesced) = duplicate else {
            release.finish()
            Issue.record("Expected duplicate repair to coalesce")
            return
        }
        release.finish()
        _ = await active.value
        guard case .applied = await first.value else {
            Issue.record("Expected original repair to apply")
            return
        }
        #expect(store.revision == 2)
        #expect(store.state.immersiveSpace == nil)
    }

    @Test func staleFeatureCannotCompleteSiblingPresentation() async throws {
        let store = RouterStore<ProbeParent>(initialState: .rootStack(path: [.feature(.home)]))
        let feature = RouterFeatureScope(parent: store.scope(), mapping: probeMapping)
        _ = await store.perform(.replaceStack([.sibling]))
        var events = store.events.makeAsyncIterator()
        let presentation = Task { @MainActor in await store.scope().present(.sibling, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        #expect(feature.node == nil)
        var rejected = false
        do { try await feature.finishPresentation(returning: "wrong-owner") }
        catch { rejected = true }
        #expect(rejected)
        #expect(store.revision == 2)
        presentation.cancel()
        let result = await presentation.value
        #expect(result != .value("wrong-owner"))
    }

    @Test func staleFeatureCannotUseTypedCompletionAgainstSiblingPresentation() async throws {
        let store = RouterStore<ProbeParent>(initialState: .rootStack(path: [.feature(.home)]))
        let feature = RouterFeatureScope(parent: store.scope(), mapping: probeMapping)
        _ = await store.perform(.replaceStack([.sibling]))
        var events = store.events.makeAsyncIterator()
        let presentation = Task { @MainActor in
            await store.scope().present(.feature(.detail), expecting: String.self)
        }
        while let event = await events.next() {
            if case .committed = event { break }
        }
        let request = RouterPresentationRequest<ProbeChild, String>(route: .detail)
        await #expect(throws: (any Error).self) {
            try await feature.finishPresentation(request, returning: "wrong-owner")
        }
        #expect(store.scope().observedPresentation?.route == .feature(.detail))
        presentation.cancel()
        #expect(await presentation.value != .value("wrong-owner"))
    }
}
