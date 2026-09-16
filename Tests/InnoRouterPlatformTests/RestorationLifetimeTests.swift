import Foundation
import SwiftUI
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

#if canImport(AppKit) || (canImport(UIKit) && !os(watchOS))
private enum LifetimeRoute: String, DestinationRoute, Codable {
    case saved, current

    @MainActor
    static func destination(for route: Self) -> some View {
        Text(verbatim: route.rawValue)
    }
}

private final class LifetimeStorage: RouterSnapshotStorage {
    private let bytes: Mutex<Data?>
    private let loads = Mutex(0)

    init(_ data: Data) { bytes = Mutex(data) }
    var loadCount: Int { loads.withLock { $0 } }
    func load() -> Data? {
        loads.withLock { $0 += 1 }
        return bytes.withLock { $0 }
    }
    func save(_ data: Data) { bytes.withLock { $0 = data } }
    func remove() { bytes.withLock { $0 = nil } }
}

/// Deliberately ignores cancellation so an old worker can finish after its
/// replacement. The test releases every continuation, including on failure.
@MainActor
private final class LifetimeWorkerGate {
    private(set) var entered = 0
    private(set) var finished = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    var pendingCount: Int { waiters.count }

    func wait() async {
        await withCheckedContinuation { continuation in
            entered += 1
            waiters[entered] = continuation
        }
    }
    func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume() }
    func didFinish() { finished += 1 }
    func releaseAll() {
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class RestorationMount {
    #if canImport(AppKit)
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    #else
    private let host: UIHostingController<AnyView>
    private let window: UIWindow
    #endif

    init(_ content: AnyView) {
        #if canImport(AppKit)
        host = NSHostingView(rootView: content)
        window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 240, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        #else
        host = UIHostingController(rootView: content)
        window = UIWindow(frame: .init(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        #endif
        layout()
    }

    func replace(_ content: AnyView) { host.rootView = content; layout() }
    func removeRoot() { replace(AnyView(Color.clear)) }
    func layout() {
        #if canImport(AppKit)
        host.layoutSubtreeIfNeeded()
        #else
        host.view.layoutIfNeeded()
        #endif
    }
    func close() {
        #if canImport(AppKit)
        window.contentView = nil
        window.orderOut(nil)
        #else
        host.beginAppearanceTransition(false, animated: false)
        host.endAppearanceTransition()
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}

@Suite("Mounted restoration lifetime", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RestorationLifetimeTests {
    @Test("A late detached worker cannot remove its mounted replacement")
    func lastDetachAndLateWorker() async throws {
        let (store, driver, storage, gate) = try fixture()
        let mount = RestorationMount(root(driver))
        defer { gate.releaseAll(); mount.close(); driver.stop() }
        try await until { gate.entered == 1 && driver.activationWaiterCount == 1 }
        #expect(storage.loadCount == 0)
        mount.removeRoot()
        try await until { driver.attachmentCount == 0 && store.eventObservationCount == 0 }
        #expect(driver.activationWaiterCount == 0)
        #expect(driver.status == .inactive)

        mount.replace(root(driver))
        try await until { gate.entered == 2 && driver.activationWaiterCount == 1 }
        gate.release(1)
        try await until { gate.finished == 1 }
        #expect(driver.attachmentCount == 1)
        #expect(driver.activationWaiterCount == 1)
        #expect(store.eventObservationCount == 1)
        #expect(storage.loadCount == 0)
        #expect(store.revision == 0)

        gate.release(2)
        try await until { gate.finished == 2 }
        #expect(store.state.root == .stack(path: [.saved]))
        #expect(store.revision == 1)
        #expect(storage.loadCount == 1)
        #expect(driver.activationWaiterCount == 0)
        mount.removeRoot()
        try await until { driver.attachmentCount == 0 && store.eventObservationCount == 0 }
        #expect(driver.status == .inactive)
        #expect(gate.pendingCount == 0)
    }

    @Test("Mounted stop and two reconnects do not replay the stopped restore")
    func stoppedRootReconnects() async throws {
        let (store, driver, storage, gate) = try fixture()
        let mount = RestorationMount(root(driver))
        defer { gate.releaseAll(); mount.close(); driver.stop() }
        try await until { gate.entered == 1 }
        _ = await store.perform(.push(.current))
        driver.stop()
        #expect(driver.activationWaiterCount == 0)
        #expect(store.eventObservationCount == 0)
        mount.removeRoot()
        await drainUI()

        for cycle in 0 ..< 2 {
            mount.replace(root(driver))
            try await until { driver.attachmentCount == 1 && store.eventObservationCount == 1 }
            #expect(driver.lastActivation == .observationResumed)
            if cycle == 0 {
                gate.release(1)
                try await until { gate.finished == 1 }
            }
            #expect(driver.status == .active)
            #expect(driver.activationWaiterCount == 0)
            #expect(store.state.root == .stack(path: [.current]))
            #expect(store.revision == 1)
            #expect(storage.loadCount == 0)
            mount.removeRoot()
            try await until { driver.attachmentCount == 0 && store.eventObservationCount == 0 }
            #expect(driver.status == .inactive)
        }
        #expect(gate.entered == 1)
        #expect(gate.pendingCount == 0)
    }

    @Test("Natural removal preserves a shared owner and latest navigation")
    func sharedRootsAndPreWorkerNavigation() async throws {
        let (store, driver, storage, gate) = try fixture()
        let first = RestorationMount(root(driver))
        let second = RestorationMount(root(driver))
        defer { gate.releaseAll(); first.close(); second.close(); driver.stop() }
        try await until { gate.entered == 1 && driver.attachmentCount == 2 }
        first.removeRoot()
        try await until { driver.attachmentCount == 1 }
        #expect(store.eventObservationCount == 1)
        _ = await store.perform(.push(.current))
        gate.release(1)
        try await until { gate.finished == 1 }
        #expect(storage.loadCount == 1)
        #expect(store.state.root == .stack(path: [.current]))
        #expect(store.revision == 1)
        #expect(driver.status == .active)
        #expect(driver.activationWaiterCount == 0)
        second.removeRoot()
        try await until { driver.attachmentCount == 0 && store.eventObservationCount == 0 }
        #expect(driver.status == .inactive)
        #expect(gate.pendingCount == 0)
    }

    private func fixture() throws -> (
        RouterStore<LifetimeRoute>, RouterRestorationDriver<LifetimeRoute>, LifetimeStorage, LifetimeWorkerGate
    ) {
        let codec = try RouterSnapshotCodec<LifetimeRoute>(currentVersion: 1)
        let storage = LifetimeStorage(try codec.encode(.rootStack(path: [.saved])))
        let gate = LifetimeWorkerGate()
        var configuration = RouterStoreConfiguration<LifetimeRoute>()
        configuration.runtimeDependencies.beforeRestorationWorker = { await gate.wait() }
        configuration.runtimeDependencies.didFinishRestorationWorker = { gate.didFinish() }
        let store = RouterStore(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store, codec: codec, storage: storage, saveDebounce: .seconds(3_600)
        )
        return (store, driver, storage, gate)
    }

    private func root(_ driver: RouterRestorationDriver<LifetimeRoute>) -> AnyView {
        // The modifier under test needs a mounted view, not an App Scene.
        // Keep SceneStorage/URL handling in the separate native consumer probe.
        AnyView(Text(verbatim: "Root").routerStateRestoration(driver))
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LifetimeTimeout() }
            await drainUI()
        }
    }

    private func drainUI() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private struct LifetimeTimeout: Error {}

private enum ImmersiveLifetimeRoute: DestinationRoute, RouterSceneRoute {
    case theater
    static let routerScenes: [RouterSceneDescriptor<Self>] = [
        .init(route: .theater, id: "theater", style: .immersiveSpace),
    ]
    @MainActor
    static func destination(for route: Self) -> some View { Text("Theater") }
}

@MainActor
private final class ImmersiveLifetimeObservation {
    var appeared = false
    var renderedRevision: UInt64?
    var finished = 0
}

@MainActor
private struct ImmersiveLifetimeRoot: View {
    let store: RouterStore<ImmersiveLifetimeRoute>
    let observation: ImmersiveLifetimeObservation
    var body: some View {
        RouterImmersiveSpaceHost(id: "theater", store: store)
            .onAppear { observation.appeared = true }
            .onChange(of: store.revision, initial: true) { _, revision in
                observation.renderedRevision = revision
            }
    }
}

@Suite("Mounted immersive lifetime", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MountedImmersiveLifetimeTests {
    @Test("Native disappearance owns its appearance token", arguments: [false, true])
    func disappearanceOwnership(replaceBeforeDetach: Bool) async throws {
        let observation = ImmersiveLifetimeObservation()
        var dependencies = RouterRuntimeDependencies.live
        dependencies.didFinishImmersiveDisappearance = { observation.finished += 1 }
        var configuration = RouterStoreConfiguration<ImmersiveLifetimeRoute>()
        configuration.runtimeDependencies = dependencies
        let store = RouterStore(
            initialState: try RouterState<ImmersiveLifetimeRoute>(
                immersiveSpace: .init(id: "theater", route: .theater)
            ),
            configuration: configuration
        )
        let mount = RestorationMount(AnyView(ImmersiveLifetimeRoot(store: store, observation: observation)))
        defer { mount.close() }
        try await until { observation.appeared }
        let firstLifetime = store.immersiveSpaceLifecycleToken
        if replaceBeforeDetach {
            _ = await store.perform(.dismissImmersiveSpace)
            _ = await store.perform(.enterImmersiveSpace(.init(id: "theater", route: .theater)))
            try await until { observation.renderedRevision == 2 }
            #expect(store.immersiveSpaceLifecycleToken != firstLifetime)
            #expect(observation.finished == 0)
        }
        mount.removeRoot()
        try await until { observation.finished == 1 }
        #expect((store.state.immersiveSpace != nil) == replaceBeforeDetach)
        #expect(store.revision == (replaceBeforeDetach ? 2 : 1))
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LifetimeTimeout() }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
#endif
