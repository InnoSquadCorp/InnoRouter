import Foundation
import SwiftUI
import Testing
import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

#if canImport(AppKit) || (canImport(UIKit) && !os(watchOS))
private enum RestoredHostRoute: String, Codable, DestinationRoute, RouterTabRoute, DeepLinkRoute {
    case home, settings, detail
    enum Tab: String, RouterTab {
        case home, settings
        var title: LocalizedStringResource { self == .home ? "Home" : "Settings" }
        var systemImage: String { "circle" }
        var routerScopeID: RouterScopeID { .init(rawValue) }
    }
    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home), .init(tab: .settings, root: .settings),
    ]
    static func resolveDeepLink(_ url: URL) -> Self? {
        guard url.scheme == "innorouter-test", url.host == "tabs.test" else { return nil }
        switch url.path {
        case "/settings": return .settings
        case "/detail": return .detail
        default: return nil
        }
    }
    static func destination(for route: Self) -> some View { RestoredTabDestination(route: route) }
}

@MainActor
private final class RestoredTabRecorder {
    struct Appearance: Sendable {
        let route: RestoredHostRoute
        let path: [RestoredHostRoute]
        let scope: RouterScopePath?
    }
    let appearances = AsyncStream<Appearance>.makeStream()
    func waitFor(_ route: RestoredHostRoute, path: [RestoredHostRoute], scope: RouterScopePath) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in self.appearances.stream {
                    if event.route == route, event.path == path, event.scope == scope { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
    }
}

private struct RestoredTabRecorderKey: EnvironmentKey {
    static let defaultValue: RestoredTabRecorder? = nil
}

private extension EnvironmentValues {
    var restoredTabRecorder: RestoredTabRecorder? {
        get { self[RestoredTabRecorderKey.self] }
        set { self[RestoredTabRecorderKey.self] = newValue }
    }
}

private struct RestoredTabDestination: View {
    @Environment(\.restoredTabRecorder) private var recorder
    @EnvironmentRouterState(RestoredHostRoute.self) private var state
    let route: RestoredHostRoute
    var body: some View {
        Text(route.rawValue)
            .accessibilityIdentifier("restored-tab-" + route.rawValue)
            .onAppear {
                recorder?.appearances.continuation.yield(.init(route: route, path: state.path, scope: state.scopePath))
            }
            .onChange(of: state.path) { _, path in
                // Native stacks may retain their root instead of re-running
                // onAppear when popping. Observe its actual scoped reader.
                recorder?.appearances.continuation.yield(.init(route: route, path: path, scope: state.scopePath))
            }
    }
}

@Suite("Restored tab native host", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterRestoredTabHostTests {
    @Test("Restored tabs mount with their state reader and production URL submission")
    func mountedRestorationAndURLs() async throws {
        typealias R = RestoredHostRoute
        let catalog = try RouterTabCatalog(R.routerTabs)
        let topology = RouterTabRestorationTopology(catalog: catalog)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let legacy = try RouterState<R>(root: .container(.init(
            style: .tabs, selection: "legacy", branches: [.init(id: "home"), .init(id: "legacy")]
        )))
        let store = RouterStore<R>()
        _ = try await store.restore(from: codec.encode(legacy), using: codec, tabTopology: topology)
        let host = try RouterTabHost(store: store, catalog: catalog, allowingOrphanedBranches: true)
        let recorder = RestoredTabRecorder()
        defer { recorder.appearances.continuation.finish() }
        let view = host.environment(\.restoredTabRecorder, recorder)
#if canImport(AppKit)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 640, height: 480))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
#else
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
#endif
        #expect(await recorder.waitFor(.home, path: [], scope: ["home"]))
        #expect(RouterStateReader(scope: store.scope()).selection == "home")
        let arbiter = RouterDeepLinkArbiter()
        let context = RouterDeepLinkContext(arbiter: arbiter, depth: 0)
        let source = RouterDeepLinkSource()
        let settingsURL = try #require(URL(string: "innorouter-test://tabs.test/settings"))
        submitRouterPlanLink(R.self, url: settingsURL, scope: store.scope(), context: context,
                             source: source, handling: nil, fallbackPlan: host.defaultLinkPlan)
        arbiter.flush(settingsURL)
        #expect(await recorder.waitFor(.settings, path: [], scope: ["settings"]))
        #expect(RouterStateReader(scope: store.scope()).selection == "settings")
        let detailURL = try #require(URL(string: "innorouter-test://tabs.test/detail"))
        submitRouterPlanLink(R.self, url: detailURL, scope: store.scope(), context: context,
                             source: source, handling: nil, fallbackPlan: host.defaultLinkPlan)
        arbiter.flush(detailURL)
        #expect(await recorder.waitFor(.detail, path: [.detail], scope: ["settings"]))
        #expect(store.scope(at: ["legacy"]).node == .stack())
        let saved = try await store.snapshot(using: codec)
        let reopened = RouterStore<R>()
        _ = try await reopened.restore(from: saved, using: codec, tabTopology: topology)
        #expect(reopened.state == store.state)
        _ = await store.scope(at: ["settings"]).perform(.pop(count: 1), context: .init(source: .system))
        #expect(await recorder.waitFor(.settings, path: [], scope: ["settings"]))
    }
}
#endif
