import SwiftUI
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

// macOS only. On iOS, iPadOS, tvOS, and visionOS the CI simulators never
// delivered the probe's `.transaction` callbacks to this off-screen,
// scene-less window, so every case timed out before the first render was
// observed; the cause lies in the harness, not in the Store. The guarantee
// these cases check end to end on macOS, that an immediate commit runs inside
// the caller's transaction, is platform independent and is also asserted by
// `RouterImmediateDispatchTests.commitInsideTransaction` on every platform.
#if os(macOS)
import AppKit
private enum AnimatedRoute: String, DestinationRoute {
    case detail, second

    @MainActor
    static func destination(for route: Self) -> some View { Text(route.rawValue) }
}

/// What one SwiftUI update of the probe saw: the path depth it rendered and
/// whether the transaction of that update carried an animation.
private struct ProbeUpdate: Sendable, Equatable {
    var depth: Int
    var animated: Bool
}

private final class AnimationProbeLog: Sendable {
    private let storage = Mutex<[ProbeUpdate]>([])

    var updates: [ProbeUpdate] { storage.withLock { $0 } }
    func record(_ update: ProbeUpdate) { storage.withLock { $0.append(update) } }
    func animated(atDepth depth: Int) -> [Bool] {
        updates.filter { $0.depth == depth }.map(\.animated)
    }
}

@MainActor
private final class RouterBox {
    var router: RouterActions<AnimatedRoute>?
}

/// Takes the router from the environment exactly as application code does.
private struct RouterCapture: View {
    @EnvironmentRouter(AnimatedRoute.self) private var router
    let box: RouterBox

    var body: some View { capture() }

    private func capture() -> some View {
        box.router = router
        return Text("Root")
    }
}

/// Reads the property the host's `NavigationStack` path binding reads, and
/// reports the transaction SwiftUI used for the update that rendered it.
private struct PathProbe: View {
    let scope: RouterScope<AnimatedRoute>
    let log: AnimationProbeLog

    var body: some View {
        let depth = scope.observedPath.count
        // An animatable child makes SwiftUI resolve the transaction for it.
        Color.clear
            .frame(width: CGFloat(10 + depth), height: 1)
            .transaction { log.record(.init(depth: depth, animated: $0.animation != nil)) }
    }
}

@MainActor
private final class AnimationMount {
    private let host: NSHostingView<AnyView>
    private let window: NSWindow

    init(_ content: AnyView) {
        host = NSHostingView(rootView: content)
        window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        layout()
    }

    func layout() { host.layoutSubtreeIfNeeded() }

    func close() {
        window.contentView = nil
        window.orderOut(nil)
    }
}

/// `RouterDispatchTiming.immediateWhenIdle` exists so that a caller's SwiftUI
/// transaction wraps the navigation change. These tests mount a real
/// `RouterHost` and check the transaction of the update that renders the new
/// path, for both timings.
@Suite("Immediate dispatch animation", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ImmediateDispatchAnimationTests {
    private typealias R = AnimatedRoute

    private struct Fixture {
        let store: RouterStore<R>
        let router: RouterActions<R>
        let log: AnimationProbeLog
        let mount: AnimationMount
    }

    private func makeFixture(_ timing: RouterDispatchTiming) async throws -> Fixture {
        var configuration = RouterStoreConfiguration<R>(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
        ))
        configuration.dispatchTiming = timing
        let store = try RouterStore<R>(configuration: configuration)
        let log = AnimationProbeLog()
        let box = RouterBox()
        let mount = AnimationMount(AnyView(VStack(spacing: 0) {
            RouterHost(store: store) { RouterCapture(box: box) }
            PathProbe(scope: store.scope(), log: log)
        }))
        try await until(pumping: mount) { box.router != nil && !log.animated(atDepth: 0).isEmpty }
        return Fixture(store: store, router: try #require(box.router), log: log, mount: mount)
    }

    private func until(pumping mount: AnimationMount, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AnimationProbeTimeout() }
            mount.layout()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test("Immediate timing renders the pushed path inside the caller's animation")
    func immediatePushIsAnimated() async throws {
        let fixture = try await makeFixture(.immediateWhenIdle)
        defer { fixture.mount.close() }

        withAnimation(.linear(duration: 0.2)) {
            _ = fixture.router.go(.detail)
        }
        #expect(fixture.store.state.root == .stack(path: [.detail]))

        try await until(pumping: fixture.mount) { !fixture.log.animated(atDepth: 1).isEmpty }
        #expect(fixture.log.animated(atDepth: 1).first == true)
    }

    @Test("Deferred timing commits after the caller's animation scope has ended")
    func deferredPushIsNotAnimated() async throws {
        let fixture = try await makeFixture(.deferred)
        defer { fixture.mount.close() }

        let task = withAnimation(.linear(duration: 0.2)) {
            fixture.router.go(.detail)
        }
        #expect(fixture.store.state.root == .stack(path: []))
        guard case .applied = await task.value else {
            Issue.record("The deferred push did not apply")
            return
        }

        try await until(pumping: fixture.mount) { !fixture.log.animated(atDepth: 1).isEmpty }
        #expect(fixture.log.animated(atDepth: 1).allSatisfy { $0 == false })
    }

    @Test("An immediate request without an animation scope stays unanimated")
    func immediatePushWithoutAnimation() async throws {
        let fixture = try await makeFixture(.immediateWhenIdle)
        defer { fixture.mount.close() }

        fixture.router.go(.detail)

        try await until(pumping: fixture.mount) { !fixture.log.animated(atDepth: 1).isEmpty }
        #expect(fixture.log.animated(atDepth: 1).allSatisfy { $0 == false })
    }

    @Test("An animated pop and an explicitly disabled animation both reach the render")
    func immediatePopAndDisabledAnimation() async throws {
        let fixture = try await makeFixture(.immediateWhenIdle)
        defer { fixture.mount.close() }

        var disabled = Transaction()
        disabled.disablesAnimations = true
        withTransaction(disabled) { _ = fixture.router.goMany([.detail, .second]) }
        try await until(pumping: fixture.mount) { !fixture.log.animated(atDepth: 2).isEmpty }
        #expect(fixture.log.animated(atDepth: 2).allSatisfy { $0 == false })

        withAnimation(.linear(duration: 0.2)) { _ = fixture.router.back() }
        try await until(pumping: fixture.mount) { !fixture.log.animated(atDepth: 1).isEmpty }
        #expect(fixture.log.animated(atDepth: 1).first == true)
    }
}

private struct AnimationProbeTimeout: Error {}
#endif
