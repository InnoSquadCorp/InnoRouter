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
final class VisionProbeModel: RouterImmersiveAppearanceObserver {
    var status = "Starting"
    var requestedDeferral: RouterDeferralID?
    var policyEntries = 0 { didSet { notifyNativeWaiters() } }
    var appeared = 0 { didSet { notifyNativeWaiters() } }
    var isPresented = false { didSet { notifyNativeWaiters() } }
    var didRun = false
    @ObservationIgnored private var injectedActivation: RouterImmersiveActivation?
    @ObservationIgnored private var originalBoundActions: RouterImmersiveSceneActions?
    @ObservationIgnored private var injectRestoration = CommandLine.arguments.contains("--injected-restoration")
    var injectedRepairObserved = false { didSet { notifyNativeWaiters() } }
    var completedOpenings = 0 { didSet { notifyNativeWaiters() } }
    var completedDismissals = 0 { didSet { notifyNativeWaiters() } }
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
            ], onEvent: { [weak self] event in
                guard let self, self.injectRestoration, self.requestedDeferral != nil else { return }
                if case .committed(_, let before, let after, _, _) = event,
                   before.immersiveSpace != nil, after.immersiveSpace == nil {
                    self.injectedRepairObserved = true
                }
            }))
        } catch {
            preconditionFailure("Invalid native scene probe configuration: \(error)")
        }
    }

    // Fault injection only: the OS still opens a real native scene. Its value
    // is captured from SwiftUI, while library admission is held until a real
    // Store repair commits. No timer orders either boundary.
    func interceptNativeAppearance(_ activation: RouterImmersiveActivation) -> Bool {
        guard injectRestoration, requestedDeferral != nil,
              let record = store.currentImmersiveActivation(activation) else { return false }
        record.nativeVisible = true
        injectedActivation = activation
        notifyNativeWaiters()
        trace("fault.bound-value.captured request=\(activation.requestID)")
        return true
    }

    private func installRestorationFault() throws {
        guard let actions = store.sceneRestorationRegistry.immersiveActions,
              let owner = store.sceneRestorationRegistry.immersiveActionsOwner else {
            throw VisionProbeFailure(message: "Missing surviving driver actions")
        }
        if originalBoundActions == nil { originalBoundActions = actions }
        guard let original = originalBoundActions, let openBound = original.openActivation else {
            throw VisionProbeFailure(message: "Missing native value open action")
        }
        store.sceneRestorationRegistry.installImmersiveActions(.init(
            open: original.open, dismiss: original.dismiss,
            openActivation: { [weak self] activation in
                let actual = await openBound(activation)
                self?.log("NATIVE_FAULT request=\(activation.requestID) actualOSResult=\(actual) injectedLibraryResult=error")
                return actual == .opened ? .error : actual
            }
        ), owner: owner)
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

    @ObservationIgnored private var nativeWaiters: [(UUID, () -> Bool, CheckedContinuation<Void, Error>)] = []

    private func notifyNativeWaiters() {
        let ready = nativeWaiters.filter { $0.1() }
        nativeWaiters.removeAll { candidate in ready.contains { $0.0 == candidate.0 } }
        ready.forEach { $0.2.resume() }
    }

    func until(_ label: String, _ condition: @escaping () -> Bool) async throws {
        if condition() { return }
        let identity = UUID()
        try await withCheckedThrowingContinuation { continuation in
            nativeWaiters.append((identity, condition, continuation))
            // Same 20-second timeout; timer only fails a hung probe. It never
            // advances a scenario or orders a native callback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let index = self.nativeWaiters.firstIndex(where: { $0.0 == identity }) else { return }
                self.nativeWaiters.remove(at: index).2.resume(throwing: VisionProbeFailure(message: "Timeout: " + label))
            }
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
                    self.isPresented && self.completedOpenings > priorOpenings
                }
                let oldScopePrecondition = store.scope(at: .immersiveSpace("theater")).combinedExecutionPrecondition(nil)
                injectedActivation = nil
                injectedRepairObserved = false
                if injectRestoration { try installRestorationFault() }
                let deferralID = RouterDeferralID()
                requestedDeferral = deferralID
                let previousEntries = policyEntries
                let previousAppearances = appeared
                nativeCloseInFlight = true
                log("NATIVE_CLOSE " + resolution)
                await closeNative()
                nativeCloseInFlight = false
                trace("native.close.return")
                try await until("native closure enters policy") { self.policyEntries > previousEntries }
                if injectRestoration {
                    try await until("injected error repair commits after real native appearance") {
                        self.injectedRepairObserved && self.injectedActivation != nil && self.isPresented
                    }
                    guard store.state.immersiveSpace == nil, let activation = injectedActivation else {
                        throw VisionProbeFailure(message: "Injection did not commit native failure repair")
                    }
                    let repairRevision = store.revision
                    log("NATIVE_FAULT_REPAIR revision=\(repairRevision) nativePresented=true canonical=false")
                    guard await store.admitAttributedImmersiveAppearance(activation),
                          store.revision == repairRevision + 1,
                          oldScopePrecondition?(store.state) != nil else {
                        throw VisionProbeFailure(message: "Attributed recovery did not commit with fresh scope")
                    }
                    log("NATIVE_FAULT_RECOVERED revision=\(store.revision) request=\(activation.requestID)")
                }
                try await until("canonical immersive space reopens") { self.isPresented && self.appeared > previousAppearances }
                guard store.state.immersiveSpace?.id == "theater" else {
                    throw VisionProbeFailure(message: "Deferred closure removed canonical space")
                }
                log("NATIVE_REOPEN " + resolution)
                requestedDeferral = nil
                switch resolution {
                case "allow":
                    _ = await store.resolveDeferred(deferralID, with: .allow)
                    try await until("allow closes native and canonical space") {
                        !self.isPresented && self.store.state.immersiveSpace == nil
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
                    try await until("cleanup closes space") { !self.isPresented && self.store.state.immersiveSpace == nil }
                }
                if !CommandLine.arguments.contains("--rapid-reopen") {
                    try await until("driver finishes native dismissal") { self.completedDismissals > priorDismissals }
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
        RouterImmersiveSpaceScene(
            id: "theater", store: model.store,
            nativeAppearance: {
                model.appeared += 1
                model.isPresented = true
                model.trace("native.appear")
            },
            nativeDisappearance: {
                model.isPresented = false
                model.trace("native.disappear")
            },
            appearanceObserver: model
        )
    }
}
#endif
