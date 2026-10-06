#if os(visionOS)
import SwiftUI
import InnoRouter
#if DEBUG
@testable import InnoRouterSwiftUI
#endif

@Router
enum VisionProbeRoute {
    @Scene(.immersiveSpace, id: "theater")
    case theater
    var destination: some View { Text("Native immersive probe").padding() }
}

@MainActor
@Observable
final class VisionProbeModel {
    var status = "Starting"
    var requestedDeferral: RouterDeferralID?
    var policyEntries = 0
    var appeared = 0
    var isPresented = false
    var didRun = false
    var completedOpenings = 0
    var completedDismissals = 0
    @ObservationIgnored private var nativeCloseInFlight = false
    @ObservationIgnored private var lifecycleTrace: [String] = []
    @ObservationIgnored lazy var store = makeStore()

    private func makeStore() -> RouterStore<VisionProbeRoute> {
        do {
            return try VisionProbeRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(root: .stack, immersiveSpaces: .init(
                entries: [.init("theater", shape: .stack)], declaration: { _ in "theater" }
            )), policies: [
                RouterPolicy(name: "confirm-native-close") { [weak self] transition in
                    if case .dismissImmersiveSpace = transition.action, let self, let id = self.requestedDeferral {
                        self.trace("policy.defer")
                        self.policyEntries += 1
                        return .deferRequest(id)
                    }
                    return .allow
                }
            ]))
        } catch {
            preconditionFailure("Invalid native scene probe configuration: \(error)")
        }
    }

    func log(_ value: String) {
        trace(value)
        status = value
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    // Probe-only observation: no output or suspension in native callbacks.
    // Canonical state at each callback distinguishes a late appearance from a
    // queued repair that removes an already observed space. Wall time permits
    // correlation with the Simulator's system log when native open fails.
    func trace(_ event: String) {
        guard lifecycleTrace.count < 256 else { return }
        lifecycleTrace.append(
            "TRACE \(lifecycleTrace.count) time=\(Date().timeIntervalSince1970) "
                + "revision=\(store.revision) canonical=\(store.state.immersiveSpace != nil) "
                + "presented=\(isPresented) appearances=\(appeared) "
                + "closeInFlight=\(nativeCloseInFlight) event=\(event)"
        )
    }

    private func flushTrace() {
#if DEBUG
        RouterSceneLifecycleTrace.flush()
#endif
        FileHandle.standardOutput.write(Data((lifecycleTrace.joined(separator: "\n") + "\n").utf8))
    }

    func until(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VisionProbeFailure(message: "Timeout: " + label) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func run(closeNative: () async -> Void) async {
        guard !didRun else { return }
        didRun = true
        do {
            let resolutions: [String]
            let supported = ["allow", "reject", "cancel"]
            if let index = CommandLine.arguments.firstIndex(of: "--resolution") {
                guard index + 1 < CommandLine.arguments.count,
                      supported.contains(CommandLine.arguments[index + 1]) else {
                    throw VisionProbeFailure(message: "Expected --resolution allow, reject, or cancel")
                }
                resolutions = [CommandLine.arguments[index + 1]]
            } else {
                resolutions = supported
            }
            for resolution in resolutions {
                let priorOpenings = completedOpenings
                let priorDismissals = completedDismissals
                requestedDeferral = nil
                guard case .applied = await store.perform(.enterImmersiveSpace(.init(id: "theater", route: .theater))) else {
                    throw VisionProbeFailure(message: "Immersive entry rejected")
                }
                try await until("native immersive opening completes") {
                    isPresented && completedOpenings > priorOpenings
                }
                let deferralID = RouterDeferralID()
                requestedDeferral = deferralID
                let previousEntries = policyEntries
                let previousAppearances = appeared
                nativeCloseInFlight = true
                log("NATIVE_CLOSE " + resolution)
                await closeNative()
                nativeCloseInFlight = false
                trace("native.close.return")
                try await until("native closure enters policy") { policyEntries > previousEntries }
                try await until("canonical immersive space reopens") { isPresented && appeared > previousAppearances }
                guard store.state.immersiveSpace?.id == "theater" else {
                    throw VisionProbeFailure(message: "Deferred closure removed canonical space")
                }
                log("NATIVE_REOPEN " + resolution)
                requestedDeferral = nil
                switch resolution {
                case "allow":
                    _ = await store.resolveDeferred(deferralID, with: .allow)
                    try await until("allow closes native and canonical space") {
                        !isPresented && store.state.immersiveSpace == nil
                    }
                case "reject":
                    _ = await store.resolveDeferred(deferralID, with: .reject("Keep open"))
                    guard isPresented, store.state.immersiveSpace?.id == "theater" else {
                        throw VisionProbeFailure(message: "Reject lost space")
                    }
                default:
                    _ = await store.cancelDeferred(deferralID)
                    guard isPresented, store.state.immersiveSpace?.id == "theater" else {
                        throw VisionProbeFailure(message: "Cancellation lost space")
                    }
                }
                if store.state.immersiveSpace != nil {
                    _ = await store.perform(.dismissImmersiveSpace)
                    try await until("cleanup closes space") { !isPresented && store.state.immersiveSpace == nil }
                }
                if !CommandLine.arguments.contains("--rapid-reopen") {
                    try await until("driver finishes native dismissal") { completedDismissals > priorDismissals }
                }
                log("PASS " + resolution)
            }
            log("PASS native visionOS " + resolutions.joined(separator: "/"))
            flushTrace()
            exit(0)
        } catch {
            log("FAIL " + String(describing: error))
            flushTrace()
            exit(1)
        }
    }
}

private struct VisionProbeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct VisionProbeController: View {
    let model: VisionProbeModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    var body: some View {
        Text(model.status).padding()
            .task { await model.run { await dismissImmersiveSpace() } }
    }
}

@main
struct VisionProbeApp: App {
    @State private var model = VisionProbeModel()
    var body: some Scene {
        WindowGroup("Router Native Probe", id: "controller") {
            RouterSceneDriver(store: model.store, onEvent: { event in
                model.log("DRIVER " + String(describing: event))
                if case .openedImmersiveSpace = event { model.completedOpenings += 1 }
                if case .dismissedImmersiveSpace = event { model.completedDismissals += 1 }
            }) { VisionProbeController(model: model) }
                .onAppear { model.trace("driver.boundary.appear") }
                .onDisappear { model.trace("driver.boundary.disappear") }
        }
        ImmersiveSpace(id: "theater") {
            RouterImmersiveSpaceHost(id: "theater", store: model.store)
                .onAppear {
                    model.appeared += 1
                    model.isPresented = true
                    model.trace("native.appear")
                }
                .onDisappear {
                    model.isPresented = false
                    model.trace("native.disappear")
                }
        }
    }
}
#endif
