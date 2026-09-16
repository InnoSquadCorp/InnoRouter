#if os(visionOS)
import SwiftUI
import InnoRouter

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
    var completedDismissals = 0
    @ObservationIgnored lazy var store = RouterStore<VisionProbeRoute>(configuration: .init(policies: [
        RouterPolicy(name: "confirm-native-close") { [weak self] transition in
            if case .dismissImmersiveSpace = transition.action, let self, let id = self.requestedDeferral {
                self.policyEntries += 1
                return .deferRequest(id)
            }
            return .allow
        }
    ]))

    func log(_ value: String) {
        status = value
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
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
            for resolution in ["allow", "reject", "cancel"] {
                let priorDismissals = completedDismissals
                requestedDeferral = nil
                guard case .applied = await store.perform(.enterImmersiveSpace(.init(id: "theater", route: .theater))) else {
                    throw VisionProbeFailure(message: "Immersive entry rejected")
                }
                try await until("native immersive space appears") { isPresented }
                let deferralID = RouterDeferralID()
                requestedDeferral = deferralID
                let previousEntries = policyEntries
                let previousAppearances = appeared
                await closeNative()
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
            log("PASS native visionOS allow/reject/cancel")
            exit(0)
        } catch {
            log("FAIL " + String(describing: error))
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
                if case .dismissedImmersiveSpace = event { model.completedDismissals += 1 }
            }) { VisionProbeController(model: model) }
        }
        ImmersiveSpace(id: "theater") {
            RouterImmersiveSpaceHost(id: "theater", store: model.store)
                .onAppear { model.appeared += 1; model.isPresented = true }
                .onDisappear { model.isPresented = false }
        }
    }
}
#endif
