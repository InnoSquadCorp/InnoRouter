import Foundation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum HostedRoute: String, Codable, DestinationRoute, RouterTabRoute {
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

    static func destination(for route: Self) -> some View { Text(route.rawValue) }
}

/// A hand-written conformance whose two tabs share one scope ID, which no
/// `@Router` enum can declare because the macro rejects it at compile time.
private enum BrokenTabRoute: String, DestinationRoute, RouterTabRoute {
    case first, second

    enum Tab: String, RouterTab {
        case first, second
        var title: LocalizedStringResource { "Tab" }
        var systemImage: String { "circle" }
        var routerScopeID: RouterScopeID { "shared" }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .first, root: .first), .init(tab: .second, root: .second),
    ]

    static func destination(for route: Self) -> some View { Text(route.rawValue) }
}

/// The default hosts and the Stores declared for them need no `try` on the
/// macro-first path.
@Suite("Hosted stores and nonthrowing hosts")
@MainActor
struct RouterHostedStoreTests {
    @Test("The nonthrowing tab host renders the declared tabs")
    func nonthrowingTabHost() {
        let host = RouterTabHost(HostedRoute.self)
        #expect(host.validationFailure == nil)
    }

    @Test("An invalid hand-written catalog is reported by the host, not trapped")
    func invalidCatalogIsReported() throws {
        #expect(throws: RouterTabCatalogError.self) { _ = try RouterTabCatalog(BrokenTabRoute.routerTabs) }

        let host = RouterTabHost(BrokenTabRoute.self)
        let failure = try #require(host.validationFailure)
        // The declared tabs themselves are reported, not a generic mismatch.
        #expect(failure.code == .invalidDeclaration)
        #expect(failure.detail == .duplicateBranch)
    }

    @Test("A hosted stack Store satisfies RouterHost(store:) without a descriptor")
    func hostedStackStore() async {
        let hosted = HostedRoute.makeRouterHostStore()
        #expect(RouterHost(store: hosted) { Text("Root") }.validationFailure == nil)
        #expect(hosted.state.root == .stack(path: []))

        // The plain factory still creates a Store with no host declaration.
        let plain = HostedRoute.makeRouterStore()
        #expect(RouterHost(store: plain) { Text("Root") }.validationFailure != nil)

        guard case .applied = await hosted.perform(.push(.detail)) else {
            Issue.record("The hosted Store rejected a push")
            return
        }
        #expect(hosted.state.root == .stack(path: [.detail]))
    }

    @Test("A hosted tab Store satisfies RouterTabHost(store:) and selects the first tab")
    func hostedTabStore() throws {
        let store = try HostedRoute.makeRouterTabHostStore()
        let host = try RouterTabHost(store: store)
        #expect(host.validationFailure == nil)
        #expect(store.scope().observedSelection == "home")
        #expect(store.scope(at: ["home"]).node == .stack(path: []))
        #expect(store.scope(at: ["settings"]).node == .stack(path: []))
    }

    @Test("The hosted tab Store honours an initial tab, badges, and configuration")
    func hostedTabStoreInputs() async throws {
        var configuration = RouterStoreConfiguration<HostedRoute>()
        configuration.dispatchTiming = .immediateWhenIdle
        let store = try HostedRoute.makeRouterTabHostStore(
            initial: .settings, badges: [.home: 3, .settings: 0], configuration: configuration
        )
        _ = try RouterTabHost(store: store)
        #expect(store.scope().observedSelection == "settings")
        #expect(store.scope().observedBadges == ["home": 3])
        #expect(store.dispatchTiming == .immediateWhenIdle)
    }

    @Test("The stack factory with a configuration declares the default host unless given one")
    func stackFactoryWithConfiguration() throws {
        var configuration = RouterStoreConfiguration<HostedRoute>(dispatchTiming: .immediateWhenIdle)
        let store = try HostedRoute.makeRouterHostStore(configuration: configuration)
        #expect(RouterHost(store: store) { Text("Root") }.validationFailure == nil)
        #expect(store.dispatchTiming == .immediateWhenIdle)

        // A descriptor the caller supplies is kept, so a host with another
        // root declaration ID can be served.
        configuration.hostDescriptor = .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("app.home"))]
        )
        let custom = try HostedRoute.makeRouterHostStore(configuration: configuration)
        #expect(RouterHost(store: custom, rootDeclarationID: "app.home") { Text("Home") }.validationFailure == nil)
        #expect(RouterHost(store: custom) { Text("Root") }.validationFailure != nil)
    }

    @Test("The tab factory passes its orphan policy to the host declaration")
    func tabFactoryOrphanPolicy() throws {
        let preserving = try HostedRoute.makeRouterTabHostStore(orphanPolicy: .preserveDormant)
        #expect(try RouterTabHost(store: preserving, orphanPolicy: .preserveDormant).validationFailure == nil)

        // A descriptor already in the configuration wins over the argument.
        let catalog = try RouterTabCatalog(HostedRoute.routerTabs)
        let keeping = try HostedRoute.makeRouterTabHostStore(
            orphanPolicy: .preserveDormant,
            configuration: .init(hostDescriptor: catalog.hostDescriptor())
        )
        #expect(try RouterTabHost(store: keeping).validationFailure == nil)
    }

    @Test("An invalid catalog makes the tab Store factory throw")
    func hostedTabStoreRejectsInvalidCatalog() {
        #expect(throws: RouterTabCatalogError.self) {
            _ = try BrokenTabRoute.makeRouterTabHostStore()
        }
    }

    @Test("A hosted Store restores through a driver with no further setup")
    func hostedStoreWithRestoration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RouterFileSnapshotStorage(fileURL: directory.appending(path: "navigation.json"))
        let codec = try RouterSnapshotCodec<HostedRoute>(currentVersion: 1)

        let writerStore = try HostedRoute.makeRouterTabHostStore()
        let writer = RouterRestorationDriver(
            store: writerStore, codec: codec, storage: storage,
            tabTopology: try RouterTabRestorationTopology(of: HostedRoute.self)
        )
        _ = await writerStore.perform(.scoped("settings", .push(.detail)))
        try await writer.save()

        let store = try HostedRoute.makeRouterTabHostStore()
        let driver = RouterRestorationDriver(
            store: store, codec: codec, storage: storage,
            tabTopology: try RouterTabRestorationTopology(of: HostedRoute.self)
        )
        defer { driver.stop() }
        guard case .restored(let outcome) = try await driver.activate(), case .applied = outcome.transition else {
            Issue.record("The hosted tab Store did not restore")
            return
        }
        #expect(store.scope(at: ["settings"]).node == .stack(path: [.detail]))
        #expect(try RouterTabHost(store: store).validationFailure == nil)
    }
}
