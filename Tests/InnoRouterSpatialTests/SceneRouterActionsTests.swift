#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SwiftUI
import Testing

import InnoRouterCore
import InnoRouterSwiftUI
@testable import InnoRouterSpatial

private enum SceneActionsRoute: Route {
    case main
    case theatre
}

private enum OtherSceneActionsRoute: Route {
    case other
}

@MainActor
private final class SceneActionRecorder {
    var opened: [SceneActionsRoute] = []
    var dismissedWindows: [ScenePresentation<SceneActionsRoute>] = []
    var immersiveDismissCount = 0
}

@Suite("SceneRouterActions", .tags(.unit))
@MainActor
struct SceneRouterActionsTests {
    @Test("Named scene actions forward through one route-typed authority")
    func actionsForwardToAuthority() throws {
        let recorder = SceneActionRecorder()
        let expected = ScenePresentation<SceneActionsRoute>.window(.main)
        let actions = makeActions(recorder: recorder, returnedPresentation: expected)

        let opened = actions.open(.main)
        actions.dismissWindow(expected)
        actions.dismissImmersive()

        #expect(opened == expected)
        #expect(recorder.opened == [.main])
        #expect(recorder.dismissedWindows == [expected])
        #expect(recorder.immersiveDismissCount == 1)
    }

    @Test("Missing scene declarations degrade to nil without a fake handle")
    func missingDeclarationReturnsNil() {
        let actions = SceneRouterActions(
            authority: SceneRouterAuthority<SceneActionsRoute>(
                open: { _ in nil },
                dismissWindow: { _ in },
                dismissImmersive: {}
            ),
            environmentMissingPolicy: .logAndDegrade
        )

        #expect(actions.open(.theatre) == nil)
    }

    @Test("Reading EnvironmentSceneRouter without a host remains lazy")
    func hostlessReadIsLazy() throws {
        var didRead = false

        _ = try renderSceneRouter(
            SceneRouterProbe { _ in
                didRead = true
            }
        )

        #expect(didRead)
    }

    #if !os(visionOS)
    @Test("Off visionOS the default policy degrades instead of trapping")
    func defaultPolicyDegradesOffVisionOS() throws {
        var completed = false

        // No `.innoRouterEnvironmentMissingPolicy` modifier: the default is
        // `.crash`, which must still degrade to a logged no-op off visionOS
        // because no scene authority can ever be published here.
        _ = try renderSceneRouter(
            SceneRouterProbe { scenes in
                #expect(scenes.open(.main) == nil)
                scenes.dismissImmersive()
                completed = true
            }
        )

        #expect(completed)
    }
    #endif

    @Test("Missing authority degrades only when an action is invoked")
    func missingAuthorityDegradesAtInvocation() throws {
        var completed = false

        _ = try renderSceneRouter(
            SceneRouterProbe { scenes in
                #expect(scenes.open(.main) == nil)
                scenes.dismissImmersive()
                completed = true
            }
            .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(completed)
    }

    @Test("Nearest same-route scene authority replaces its parent")
    func nearestAuthorityWins() throws {
        let outerRecorder = SceneActionRecorder()
        let innerRecorder = SceneActionRecorder()
        let outerPresentation = ScenePresentation<SceneActionsRoute>.window(.main)
        let innerPresentation = ScenePresentation<SceneActionsRoute>.immersive(
            .theatre,
            style: .mixed
        )

        _ = try renderSceneRouter(
            VStack {
                SceneRouterProbe { scenes in
                    #expect(scenes.open(.theatre) == innerPresentation)
                }
                .sceneRouterAuthority(
                    makeAuthority(
                        recorder: innerRecorder,
                        returnedPresentation: innerPresentation
                    ),
                    for: SceneActionsRoute.self
                )
            }
            .sceneRouterAuthority(
                makeAuthority(
                    recorder: outerRecorder,
                    returnedPresentation: outerPresentation
                ),
                for: SceneActionsRoute.self
            )
        )

        #expect(innerRecorder.opened == [.theatre])
        #expect(outerRecorder.opened.isEmpty)
    }

    @Test("A different route authority cannot service the requested route type")
    func routeTypesRemainIsolated() throws {
        var otherOpenCount = 0

        let otherAuthority = SceneRouterAuthority<OtherSceneActionsRoute>(
            open: { route in
                otherOpenCount += 1
                return .window(route)
            },
            dismissWindow: { _ in },
            dismissImmersive: {}
        )

        _ = try renderSceneRouter(
            SceneRouterProbe { scenes in
                #expect(scenes.open(.main) == nil)
            }
            .sceneRouterAuthority(otherAuthority, for: OtherSceneActionsRoute.self)
            .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(otherOpenCount == 0)
    }

    private func makeActions(
        recorder: SceneActionRecorder,
        returnedPresentation: ScenePresentation<SceneActionsRoute>
    ) -> SceneRouterActions<SceneActionsRoute> {
        SceneRouterActions(
            authority: makeAuthority(
                recorder: recorder,
                returnedPresentation: returnedPresentation
            )
        )
    }

    private func makeAuthority(
        recorder: SceneActionRecorder,
        returnedPresentation: ScenePresentation<SceneActionsRoute>
    ) -> SceneRouterAuthority<SceneActionsRoute> {
        SceneRouterAuthority(
            open: { route in
                recorder.opened.append(route)
                return returnedPresentation
            },
            dismissWindow: { presentation in
                recorder.dismissedWindows.append(presentation)
            },
            dismissImmersive: {
                recorder.immersiveDismissCount += 1
            }
        )
    }
}

private struct SceneRouterProbe: View {
    @EnvironmentSceneRouter(SceneActionsRoute.self)
    private var scenes

    let action: @MainActor (SceneRouterActions<SceneActionsRoute>) -> Void

    var body: some View {
        Color.clear.onAppear {
            action(scenes)
        }
    }
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderSceneRouter<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    return hostingView
}
#else
@MainActor
private func renderSceneRouter<V: View>(_ view: V) throws {
    throw Skip("SceneRouterActionsTests require AppKit-backed SwiftUI rendering.")
}
#endif
