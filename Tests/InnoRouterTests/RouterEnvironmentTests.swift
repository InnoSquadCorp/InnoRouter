#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum RouterEnvironmentRoute: Route {
    case home
    case detail(id: String)
    case settings
}

private enum OtherRouterEnvironmentRoute: Route {
    case other
}

@MainActor
private final class RouterEnvironmentIntentRecorder {
    var navigation: [NavigationIntent<RouterEnvironmentRoute>] = []
    var modal: [ModalIntent<RouterEnvironmentRoute>] = []
    var flow: [FlowIntent<RouterEnvironmentRoute>] = []
}

@Suite("Unified RouterEnvironment", .tags(.unit))
@MainActor
struct RouterEnvironmentTests {
    @Test("RouterActions named methods map to navigation and modal intents")
    func namedActionMapping() {
        let recorder = RouterEnvironmentIntentRecorder()
        let router = makeRouter(recorder: recorder)

        router.go(.home)
        router.goMany([.detail(id: "one"), .settings])
        router.back()
        router.back(by: 2)
        router.back(to: .home)
        router.backToRoot()
        router.sheet(.detail(id: "sheet"))
        router.cover(.detail(id: "cover"))
        router.dismiss()
        router.dismissAll()

        #expect(recorder.navigation == [
            .go(.home),
            .goMany([.detail(id: "one"), .settings]),
            .back,
            .backBy(2),
            .backTo(.home),
            .backToRoot,
        ])
        #expect(recorder.modal == [
            .present(.detail(id: "sheet"), style: .sheet),
            .present(.detail(id: "cover"), style: .fullScreenCover),
            .dismiss,
            .dismissAll,
        ])
        #expect(recorder.flow.isEmpty)
    }

    @Test("RouterActions exposes explicit navigation, modal, and labeled flow sends")
    func explicitIntentSends() {
        let recorder = RouterEnvironmentIntentRecorder()
        let router = makeRouter(recorder: recorder)

        router.send(NavigationIntent.replaceStack([.settings]))
        router.send(ModalIntent.present(.home, style: .sheet))
        router.send(flow: FlowIntent.push(.detail(id: "flow")))

        #expect(recorder.navigation == [.replaceStack([.settings])])
        #expect(recorder.modal == [.present(.home, style: .sheet)])
        #expect(recorder.flow == [.push(.detail(id: "flow"))])
    }

    @Test("Reading EnvironmentRouter without a host stays lazy under crash policy")
    func hostlessReadDoesNotReportUntilActionRuns() throws {
        var didRead = false

        _ = try renderRouterEnvironment(
            RouterEnvironmentProbe { _ in
                didRead = true
            }
        )

        #expect(didRead)
    }

    @Test("Missing host reports through logAndDegrade only when an action runs")
    func missingHostDegradesAtInvocation() throws {
        var completedAction = false

        _ = try renderRouterEnvironment(
            RouterEnvironmentProbe { router in
                router.go(.home)
                completedAction = true
            }
            .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(completedAction)
    }

    @Test("Mismatched route authority degrades without dispatching another route type")
    func mismatchedRouteTypeDoesNotDispatch() throws {
        var otherRouteDispatchCount = 0
        var completedAction = false

        _ = try renderRouterEnvironment(
            RouterEnvironmentProbe { router in
                router.go(.home)
                completedAction = true
            }
            .routerAuthority(
                for: OtherRouterEnvironmentRoute.self,
                navigation: { _ in
                    otherRouteDispatchCount += 1
                }
            )
            .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(completedAction)
        #expect(otherRouteDispatchCount == 0)
    }

    @Test("Nearest same-route authority replaces the complete outer authority")
    func nearestAuthorityReplacesInsteadOfMergingCapabilities() throws {
        let outerRecorder = RouterEnvironmentIntentRecorder()
        let innerRecorder = RouterEnvironmentIntentRecorder()
        var completedActions = false

        let outerAuthority = RouterAuthority<RouterEnvironmentRoute>(
            navigation: { outerRecorder.navigation.append($0) },
            modal: { outerRecorder.modal.append($0) },
            flow: { outerRecorder.flow.append($0) }
        )
        let innerAuthority = RouterAuthority<RouterEnvironmentRoute>(
            navigation: { innerRecorder.navigation.append($0) }
        )

        _ = try renderRouterEnvironment(
            VStack {
                RouterEnvironmentProbe { router in
                    router.go(.settings)
                    router.sheet(.home)
                    router.send(flow: .push(.detail(id: "blocked")))
                    completedActions = true
                }
                .routerAuthority(innerAuthority, for: RouterEnvironmentRoute.self)
            }
            .routerAuthority(outerAuthority, for: RouterEnvironmentRoute.self)
            .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(completedActions)
        #expect(innerRecorder.navigation == [.go(.settings)])
        #expect(innerRecorder.modal.isEmpty)
        #expect(innerRecorder.flow.isEmpty)
        #expect(outerRecorder.navigation.isEmpty)
        #expect(outerRecorder.modal.isEmpty)
        #expect(outerRecorder.flow.isEmpty)
    }

    private func makeRouter(
        recorder: RouterEnvironmentIntentRecorder
    ) -> RouterActions<RouterEnvironmentRoute> {
        RouterActions(
            authority: RouterAuthority(
                navigation: { recorder.navigation.append($0) },
                modal: { recorder.modal.append($0) },
                flow: { recorder.flow.append($0) }
            )
        )
    }
}

private struct RouterEnvironmentProbe: View {
    @EnvironmentRouter(RouterEnvironmentRoute.self)
    private var router

    let action: @MainActor (RouterActions<RouterEnvironmentRoute>) -> Void

    var body: some View {
        Color.clear.onAppear {
            action(router)
        }
    }
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderRouterEnvironment<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    return hostingView
}
#else
@MainActor
private func renderRouterEnvironment<V: View>(_ view: V) throws {
    throw Skip("RouterEnvironmentTests require AppKit-backed SwiftUI rendering.")
}
#endif
