import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSpatial

private enum SceneTestRoute: String, Route {
    case main
    case theatre
    case theatreTwo
    case volume
    case secondary
}

private enum SceneTestIDs {
    static let mainWindow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let mainWindowDuplicate = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let mainWindowStale = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let volumeWindow = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let theatre = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let theatreTwo = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
}

private func makeSceneRegistry() -> SceneRegistry<SceneTestRoute> {
    SceneRegistry(
        .window(.main, id: "main-window"),
        .volumetric(.volume, id: "volume-window", size: VolumetricSize(x: 1, y: 1, z: 1)),
        .immersive(.theatre, id: "theatre-space", style: .mixed)
    )
}

private func mainWindowPresentation(
    id: UUID = SceneTestIDs.mainWindow
) -> ScenePresentation<SceneTestRoute> {
    .window(.main, id: id)
}

private func volumePresentation(
    id: UUID = SceneTestIDs.volumeWindow
) -> ScenePresentation<SceneTestRoute> {
    .volumetric(.volume, size: VolumetricSize(x: 1, y: 1, z: 1), id: id)
}

private func theatrePresentation(
    route: SceneTestRoute = .theatre,
    style: ImmersiveStyle = .mixed,
    id: UUID = SceneTestIDs.theatre
) -> ScenePresentation<SceneTestRoute> {
    .immersive(route, style: style, id: id)
}

@Suite("SceneDispatcherRegistry Tests", .tags(.unit))
struct SceneDispatcherRegistryTests {
    @Test("primary host outranks fallback anchors and fallback order is stable")
    func primaryHostOutranksFallbackAnchors() {
        var registry = SceneDispatcherRegistry()
        let fallbackOne = UUID()
        let fallbackTwo = UUID()
        let primary = UUID()

        registry.registerFallbackAnchor(fallbackOne)
        registry.registerFallbackAnchor(fallbackTwo)
        #expect(registry.electedDispatcherToken == fallbackOne)
        #expect(registry.canClaim(fallbackOne))

        let didRegisterPrimary = registry.registerPrimaryHost(primary)
        #expect(didRegisterPrimary)
        #expect(registry.electedDispatcherToken == primary)
        #expect(registry.canClaim(primary))

        registry.unregisterPrimaryHost(primary)
        #expect(registry.electedDispatcherToken == fallbackOne)

        registry.unregisterFallbackAnchor(fallbackOne)
        #expect(registry.electedDispatcherToken == fallbackTwo)
    }

    @Test("second primary host registration is rejected")
    func secondPrimaryHostRegistrationFails() {
        var registry = SceneDispatcherRegistry()
        let primaryOne = UUID()
        let primaryTwo = UUID()

        let firstRegistration = registry.registerPrimaryHost(primaryOne)
        let secondRegistration = registry.registerPrimaryHost(primaryTwo)

        #expect(firstRegistration)
        #expect(secondRegistration == false)
        #expect(registry.electedDispatcherToken == primaryOne)
    }
}

@Suite("SceneStoreState Tests", .tags(.unit))
struct SceneStoreStateTests {
    @Test("dismissImmersive rejects when nothing is active")
    func dismissImmersiveRejectsWithoutActiveScene() {
        var state = SceneStoreState<SceneTestRoute>()

        let events = state.requestDismissImmersive()

        #expect(events == [.rejected(.dismissImmersive, reason: .nothingActive)])
        #expect(state.currentScene == nil)
        #expect(state.pendingIntent == nil)
    }

    @Test("dismissImmersive supersedes a matching pending immersive open")
    func dismissImmersiveSupersedesPendingOpen() {
        var state = SceneStoreState<SceneTestRoute>()
        let immersive = theatrePresentation()

        #expect(state.requestOpen(immersive).isEmpty)

        let events = state.requestDismissImmersive()

        #expect(events == [.rejected(.open(immersive), reason: .supersededByNewerIntent)])
        #expect(state.currentScene == nil)
        #expect(state.pendingIntent == nil)
    }

    @Test("dismissWindow supersedes a matching pending window open")
    func dismissWindowSupersedesPendingOpen() {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()

        #expect(state.requestOpen(mainWindow).isEmpty)

        let events = state.requestDismissWindow(mainWindow)

        #expect(events == [.rejected(.open(mainWindow), reason: .supersededByNewerIntent)])
        #expect(state.currentScene == nil)
        #expect(state.pendingIntent == nil)
    }

    @Test("duplicate window opens queue independently before claim")
    func duplicateWindowOpensQueueIndependently() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)

        #expect(state.requestOpen(mainWindow).isEmpty)
        #expect(state.requestOpen(duplicateMainWindow).isEmpty)
        #expect(state.queuedIntents == [.open(mainWindow), .open(duplicateMainWindow)])

        let firstRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(firstRequestID) == .open(mainWindow))
        #expect(state.pendingIntent == nil)
        #expect(state.currentPendingRequestID == nil)
        #expect(
            state.completeOpen(
                mainWindow,
                accepted: true,
                requestID: firstRequestID
            ) == .broadcast(.presented(mainWindow))
        )

        let secondRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(secondRequestID) == .open(duplicateMainWindow))
        #expect(
            state.completeOpen(
                duplicateMainWindow,
                accepted: true,
                requestID: secondRequestID
            ) == .broadcast(.presented(duplicateMainWindow))
        )

        #expect(state.snapshot.windowPresentations(for: .main) == [mainWindow, duplicateMainWindow])
        #expect(state.currentScene == duplicateMainWindow)
        #expect(state.pendingIntent == nil)
    }

    @Test("missing window instance dismiss rejects with sceneInstanceNotActive")
    func dismissMissingWindowInstanceRejects() {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let staleWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowStale)

        state.attach(mainWindow)

        let events = state.requestDismissWindow(staleWindow)

        #expect(events == [.rejected(.dismissWindow(staleWindow), reason: .sceneInstanceNotActive)])
        #expect(state.currentScene == mainWindow)
        #expect(state.pendingIntent == nil)
    }

    @Test("duplicate route windows stay active independently")
    func duplicateRouteWindowsStayActiveIndependently() {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)

        state.attach(mainWindow)
        state.attach(duplicateMainWindow)

        #expect(state.snapshot.windowPresentations(for: .main) == [mainWindow, duplicateMainWindow])
        #expect(state.snapshot.activeScenes == [mainWindow, duplicateMainWindow])
        #expect(state.currentScene == duplicateMainWindow)
    }

    @Test("completeDismissal removes only the targeted duplicate window")
    func completeDismissalRemovesOnlyTargetedDuplicateWindow() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)

        state.attach(mainWindow)
        state.attach(duplicateMainWindow)
        #expect(state.requestDismissWindow(mainWindow).isEmpty)

        let requestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(requestID) == .dismissWindow(mainWindow))

        let completion = state.completeDismissal(of: mainWindow, requestID: requestID)

        #expect(completion == .broadcast(.dismissed(mainWindow)))
        #expect(state.currentScene == duplicateMainWindow)
        #expect(state.snapshot.windowPresentation(id: mainWindow.id) == nil)
        #expect(state.snapshot.windowPresentations(for: .main) == [duplicateMainWindow])
    }

    @Test("duplicate window dismissals queue independently before claim")
    func duplicateWindowDismissalsQueueIndependently() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)

        state.attach(mainWindow)
        state.attach(duplicateMainWindow)

        #expect(state.requestDismissWindow(mainWindow).isEmpty)
        #expect(state.requestDismissWindow(duplicateMainWindow).isEmpty)
        #expect(
            state.queuedIntents ==
                [.dismissWindow(mainWindow), .dismissWindow(duplicateMainWindow)]
        )

        let firstRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(firstRequestID) == .dismissWindow(mainWindow))
        #expect(state.pendingIntent == nil)
        #expect(state.currentPendingRequestID == nil)
        #expect(
            state.completeDismissal(
                of: mainWindow,
                requestID: firstRequestID
            ) == .broadcast(.dismissed(mainWindow))
        )

        let secondRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(secondRequestID) == .dismissWindow(duplicateMainWindow))
        #expect(
            state.completeDismissal(
                of: duplicateMainWindow,
                requestID: secondRequestID
            ) == .broadcast(.dismissed(duplicateMainWindow))
        )

        #expect(state.snapshot.windowPresentations(for: .main).isEmpty)
        #expect(state.currentScene == nil)
        #expect(state.pendingIntent == nil)
    }

    @Test("dismissed duplicate window detach is idempotent")
    func detachAfterExplicitDismissalIsIdempotent() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)

        state.attach(mainWindow)
        state.attach(duplicateMainWindow)
        #expect(state.requestDismissWindow(mainWindow).isEmpty)

        let requestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(requestID) == .dismissWindow(mainWindow))
        _ = state.completeDismissal(of: mainWindow, requestID: requestID)

        state.detach(mainWindow)

        #expect(state.currentScene == duplicateMainWindow)
        #expect(state.snapshot.windowPresentation(id: mainWindow.id) == nil)
        #expect(state.snapshot.windowPresentations(for: .main) == [duplicateMainWindow])
    }

    @Test("A stale lifecycle detach cannot remove a replacement that reuses the scene UUID")
    func staleDetachPreservesReplacementPresentation() {
        var state = SceneStoreState<SceneTestRoute>()
        let stalePresentation = mainWindowPresentation()
        let replacementPresentation = ScenePresentation<SceneTestRoute>.window(
            .secondary,
            id: stalePresentation.id
        )

        state.attach(stalePresentation)
        state.attach(replacementPresentation)
        state.detach(stalePresentation)

        #expect(state.currentScene == replacementPresentation)
        #expect(state.snapshot.windowPresentation(id: stalePresentation.id) == replacementPresentation)
        #expect(state.snapshot.activeScenes == [replacementPresentation])
    }

    @Test("A stale immersive detach cannot remove a replacement that reuses the scene UUID")
    func staleImmersiveDetachPreservesReplacementPresentation() {
        var state = SceneStoreState<SceneTestRoute>()
        let stalePresentation = theatrePresentation()
        let replacementPresentation = theatrePresentation(
            route: .theatreTwo,
            id: stalePresentation.id
        )

        state.attach(stalePresentation)
        state.attach(replacementPresentation)
        state.detach(stalePresentation)

        #expect(state.currentScene == replacementPresentation)
        #expect(state.snapshot.activeImmersive == replacementPresentation)
        #expect(state.snapshot.activeScenes == [replacementPresentation])
    }

    @Test("identical dismissWindow requests are deduplicated")
    func identicalDismissWindowRequestsAreDeduplicated() {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()

        state.attach(mainWindow)

        #expect(state.requestDismissWindow(mainWindow).isEmpty)
        #expect(state.requestDismissWindow(mainWindow).isEmpty)
        #expect(state.queuedIntents == [.dismissWindow(mainWindow)])
    }

    @Test("claimed immersive open preserves a follow-up dismiss until cleanup completes")
    func claimedImmersiveOpenPreservesFollowUpDismiss() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let immersive = theatrePresentation()

        #expect(state.requestOpen(immersive).isEmpty)
        let requestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(requestID) == .open(immersive))

        let events = state.requestDismissImmersive()

        #expect(events == [.rejected(.open(immersive), reason: .supersededByNewerIntent)])
        #expect(state.pendingIntent == nil)
        #expect(state.currentPendingRequestID == nil)
        #expect(state.queuedIntents == [.dismissImmersive])
        #expect(state.currentClaimedRequestID == requestID)

        let completion = state.completeOpen(
            immersive,
            accepted: true,
            requestID: requestID
        )

        #expect(completion == .cleanupSupersededImmersiveOpen)
        #expect(
            state.finishSupersededImmersiveOpenCleanup(requestID: requestID) ==
                .broadcast(.dismissed(immersive))
        )
        #expect(state.pendingIntent == nil)
        #expect(state.currentClaimedRequestID == nil)
        #expect(state.snapshot.activeImmersive == nil)
        #expect(state.currentScene == nil)
    }

    @Test("claimed immersive open preserves queued window opens until cleanup completes")
    func claimedImmersiveOpenPreservesQueuedWindowOpens() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let immersive = theatrePresentation()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)

        #expect(state.requestOpen(immersive).isEmpty)
        let requestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(requestID) == .open(immersive))

        let firstEvents = state.requestOpen(mainWindow)
        #expect(firstEvents == [.rejected(.open(immersive), reason: .supersededByNewerIntent)])
        #expect(state.queuedIntents == [.open(mainWindow)])
        #expect(state.pendingIntent == nil)
        #expect(state.currentPendingRequestID == nil)

        let secondEvents = state.requestOpen(duplicateMainWindow)
        #expect(secondEvents.isEmpty)
        #expect(state.queuedIntents == [.open(mainWindow), .open(duplicateMainWindow)])
        #expect(state.pendingIntent == nil)
        #expect(state.currentPendingRequestID == nil)

        let completion = state.completeOpen(
            immersive,
            accepted: true,
            requestID: requestID
        )

        #expect(completion == .cleanupSupersededImmersiveOpen)
        #expect(
            state.finishSupersededImmersiveOpenCleanup(requestID: requestID) ==
                SceneClaimCompletion<SceneTestRoute>.none
        )
        #expect(state.snapshot.activeImmersive == nil)
        #expect(state.queuedIntents == [.open(mainWindow), .open(duplicateMainWindow)])

        let firstWindowRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(firstWindowRequestID) == .open(mainWindow))
        #expect(
            state.completeOpen(
                mainWindow,
                accepted: true,
                requestID: firstWindowRequestID
            ) == .broadcast(.presented(mainWindow))
        )

        let secondWindowRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(secondWindowRequestID) == .open(duplicateMainWindow))
        #expect(
            state.completeOpen(
                duplicateMainWindow,
                accepted: true,
                requestID: secondWindowRequestID
            ) == .broadcast(.presented(duplicateMainWindow))
        )

        #expect(state.snapshot.windowPresentations(for: .main) == [mainWindow, duplicateMainWindow])
        #expect(state.currentScene == duplicateMainWindow)
    }

    @Test("immersive round-trip preserves duplicate window inventory")
    func immersiveRoundTripPreservesAttachedWindows() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)
        let immersive = theatrePresentation()

        state.attach(mainWindow)
        state.attach(duplicateMainWindow)
        #expect(state.requestOpen(immersive).isEmpty)

        let openRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(openRequestID) == .open(immersive))
        #expect(
            state.completeOpen(
                immersive,
                accepted: true,
                requestID: openRequestID
            ) == .broadcast(.presented(immersive))
        )
        #expect(state.currentScene == immersive)

        #expect(state.requestDismissImmersive().isEmpty)
        let dismissRequestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(dismissRequestID) == .dismissImmersive)
        #expect(
            state.completeDismissal(
                of: immersive,
                requestID: dismissRequestID
            ) == .broadcast(.dismissed(immersive))
        )

        #expect(state.snapshot.windowPresentations(for: .main) == [mainWindow, duplicateMainWindow])
        #expect(state.currentScene == duplicateMainWindow)
        #expect(state.snapshot.activeImmersive == nil)
    }

    @Test("currentScene remains a recency summary of active inventory")
    func currentSceneTracksRecencySummary() {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)
        let volume = volumePresentation()

        state.attach(mainWindow)
        #expect(state.currentScene == mainWindow)

        state.attach(duplicateMainWindow)
        #expect(state.currentScene == duplicateMainWindow)

        state.detach(duplicateMainWindow)
        #expect(state.currentScene == mainWindow)

        state.attach(volume)
        #expect(state.currentScene == volume)
    }

    @Test("completeRejection clears claimed request and preserves committed inventory")
    func completeRejectionPreservesCommittedInventory() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()

        state.attach(mainWindow)
        #expect(state.requestDismissWindow(mainWindow).isEmpty)

        let requestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(requestID) == .dismissWindow(mainWindow))

        let completion = state.completeRejection(
            for: .dismissWindow(mainWindow),
            reason: .activeSceneMismatch,
            requestID: requestID
        )

        #expect(
            completion ==
                .broadcast(.rejected(.dismissWindow(mainWindow), reason: .activeSceneMismatch))
        )
        #expect(state.currentScene == mainWindow)
        #expect(state.pendingIntent == nil)
        #expect(state.snapshot.windowPresentation(id: mainWindow.id) == mainWindow)
    }

    @Test("completeOpen failure preserves committed inventory")
    func completeOpenFailurePreservesCurrentInventory() throws {
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let immersive = theatrePresentation()

        state.attach(mainWindow)
        #expect(state.requestOpen(immersive).isEmpty)

        let requestID = try #require(state.currentPendingRequestID)
        #expect(state.claimPendingRequest(requestID) == .open(immersive))

        let completion = state.completeOpen(
            immersive,
            accepted: false,
            requestID: requestID
        )

        #expect(
            completion ==
                .broadcast(.rejected(.open(immersive), reason: .environmentReturnedFailure))
        )
        #expect(state.currentScene == mainWindow)
        #expect(state.pendingIntent == nil)
        #expect(state.snapshot.windowPresentation(id: mainWindow.id) == mainWindow)
        #expect(state.snapshot.activeImmersive == nil)
    }
}

@Suite("SceneIntentResolver Tests", .tags(.unit))
struct SceneIntentResolverTests {
    @Test("open rejects undeclared routes")
    func openRejectsUndeclaredRoute() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        let presentation: ScenePresentation<SceneTestRoute> = .window(
            .secondary,
            id: SceneTestIDs.mainWindowStale
        )

        let resolution = resolver.resolve(
            .open(presentation),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )

        #expect(resolution == .reject(.open(presentation), reason: .sceneNotDeclared))
    }

    @Test("open rejects kind mismatch against the registry")
    func openRejectsKindMismatch() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        let presentation: ScenePresentation<SceneTestRoute> = .window(
            .theatre,
            id: SceneTestIDs.mainWindowStale
        )

        let resolution = resolver.resolve(
            .open(presentation),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )

        #expect(resolution == .reject(.open(presentation), reason: .sceneDeclarationMismatch))
    }

    @Test("open rejects size and style mismatches against the registry")
    func openRejectsMetadataMismatch() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        let volumetricMismatch: ScenePresentation<SceneTestRoute> = .volumetric(
            .volume,
            size: VolumetricSize(x: 2, y: 2, z: 2),
            id: SceneTestIDs.volumeWindow
        )
        let immersiveMismatch = theatrePresentation(style: .full)

        let volumetricResolution = resolver.resolve(
            .open(volumetricMismatch),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )
        let immersiveResolution = resolver.resolve(
            .open(immersiveMismatch),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )

        #expect(volumetricResolution == .reject(.open(volumetricMismatch), reason: .sceneDeclarationMismatch))
        #expect(immersiveResolution == .reject(.open(immersiveMismatch), reason: .sceneDeclarationMismatch))
    }

    @Test("matching declarations resolve to concrete open dispatches")
    func openResolvesMatchingDeclarations() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        let windowPresentation = mainWindowPresentation()
        let volume = volumePresentation()
        let immersive = theatrePresentation()

        let windowResolution = resolver.resolve(
            .open(windowPresentation),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )
        let volumeResolution = resolver.resolve(
            .open(volume),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )
        let immersiveResolution = resolver.resolve(
            .open(immersive),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )

        #expect(
            windowResolution ==
                .openWindow(
                    id: "main-window",
                    value: windowPresentation.id,
                    presentation: windowPresentation
                )
        )
        #expect(
            volumeResolution ==
                .openWindow(
                    id: "volume-window",
                    value: volume.id,
                    presentation: volume
                )
        )
        #expect(immersiveResolution == .openImmersive(id: "theatre-space", presentation: immersive))
    }

    @Test("fallback open authority follows the declaration rather than the window instance UUID")
    func fallbackOpenAuthorityUsesSceneDeclaration() throws {
        let scenes = makeSceneRegistry()
        let resolver = SceneIntentResolver(scenes: scenes)
        let mainDeclaration = try #require(scenes.declaration(for: .main))
        let theatreDeclaration = try #require(scenes.declaration(for: .theatre))
        let attachedWindow = mainDeclaration.presentation(id: SceneTestIDs.mainWindow)
        let anotherWindow = mainDeclaration.presentation(id: SceneTestIDs.mainWindowDuplicate)
        let theatre = theatreDeclaration.presentation(id: SceneTestIDs.theatre)

        let sameDeclarationPlan = resolver.resolve(
            .open(anotherWindow),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )
        let crossScenePlan = resolver.resolve(
            .open(theatre),
            state: SceneStoreState<SceneTestRoute>().snapshot
        )

        #expect(
            sameDeclarationPlan.isServiceableByFallback(
                attachedTo: attachedWindow,
                declaredIn: scenes
            )
        )
        #expect(
            crossScenePlan.isServiceableByFallback(
                attachedTo: attachedWindow,
                declaredIn: scenes
            ) == false
        )
    }

    @Test("dismissWindow resolves the specific instance even with duplicate routes")
    func dismissWindowUsesSpecificInstanceMembership() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let duplicateMainWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowDuplicate)
        let immersive = theatrePresentation()

        state.attach(mainWindow)
        state.attach(duplicateMainWindow)
        state.attach(immersive)

        let resolution = resolver.resolve(.dismissWindow(mainWindow), state: state.snapshot)

        #expect(
            resolution ==
                .dismissWindow(
                    id: "main-window",
                    value: mainWindow.id,
                    presentation: mainWindow
                )
        )
    }

    @Test("dismissWindow rejects a stale instance handle")
    func dismissWindowRejectsMissingInstance() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        var state = SceneStoreState<SceneTestRoute>()
        let mainWindow = mainWindowPresentation()
        let staleWindow = mainWindowPresentation(id: SceneTestIDs.mainWindowStale)

        state.attach(mainWindow)

        let resolution = resolver.resolve(.dismissWindow(staleWindow), state: state.snapshot)

        #expect(resolution == .reject(.dismissWindow(staleWindow), reason: .sceneInstanceNotActive))
    }

    @Test("dismissImmersive uses active immersive membership instead of currentScene alone")
    func dismissImmersiveUsesActiveImmersiveInventory() {
        let resolver = SceneIntentResolver(scenes: makeSceneRegistry())
        var state = SceneStoreState<SceneTestRoute>()

        state.attach(mainWindowPresentation())

        let resolution = resolver.resolve(.dismissImmersive, state: state.snapshot)

        #expect(resolution == .reject(.dismissImmersive, reason: .activeSceneMismatch))
    }

    @Test("dismissWindow rejects registry mismatches before dispatch")
    func dismissWindowRejectsRegistryMismatch() {
        let scenes = SceneRegistry<SceneTestRoute>(
            .immersive(.main, id: "main-space", style: .mixed)
        )
        let resolver = SceneIntentResolver(scenes: scenes)
        var state = SceneStoreState<SceneTestRoute>()
        let activeScene = mainWindowPresentation()

        state.attach(activeScene)

        let resolution = resolver.resolve(.dismissWindow(activeScene), state: state.snapshot)

        #expect(resolution == .reject(.dismissWindow(activeScene), reason: .sceneDeclarationMismatch))
    }
}
