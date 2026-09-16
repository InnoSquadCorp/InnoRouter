#if os(iOS)
import SwiftUI
import UIKit
import InnoRouter

@Router
enum IPadProbeRoute {
    @Scene(.window, id: "editor")
    case editor
    var destination: some View { Text("Native editor").padding() }
}

@MainActor
private final class WeakScene {
    weak var value: UIWindowScene?
    init(_ value: UIWindowScene) { self.value = value }
}

@MainActor
@Observable
final class IPadProbeModel {
    var status = "Starting"
    var requestedDeferral: RouterDeferralID?
    var policyEntries = 0
    var didRun = false
    var appeared: [UUID: Int] = [:]
    var nativeError: String?
    @ObservationIgnored private var scenes: [UUID: WeakScene] = [:]
    @ObservationIgnored lazy var store = RouterStore<IPadProbeRoute>(configuration: .init(policies: [
        RouterPolicy(name: "confirm-native-close") { [weak self] transition in
            if case .dismissWindow = transition.action, let self, let id = self.requestedDeferral {
                self.policyEntries += 1
                return .deferRequest(id)
            }
            return .allow
        }
    ]))

    func attach(_ scene: UIWindowScene, to id: UUID) {
        scenes[id] = WeakScene(scene)
        log("CAPTURE " + id.uuidString)
    }

    func nativeScene(_ id: UUID) -> UIWindowScene? {
        guard let scene = scenes[id]?.value,
              UIApplication.shared.connectedScenes.contains(scene),
              scene.activationState != .unattached else { return nil }
        return scene
    }

    func log(_ value: String) {
        status = value
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    func until(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            if let nativeError { throw IPadProbeFailure(message: nativeError) }
            guard ContinuousClock.now < deadline else {
                log("SCENES " + String(UIApplication.shared.connectedScenes.count) + "; appeared=" + String(describing: appeared))
                throw IPadProbeFailure(message: "Timeout: " + label)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func closeNative(_ id: UUID) throws {
        guard let scene = nativeScene(id) else { throw IPadProbeFailure(message: "No native scene to close") }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { [weak self] error in
            self?.nativeError = String(describing: error)
        }
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        do {
            guard UIDevice.current.userInterfaceIdiom == .pad,
                  UIApplication.shared.supportsMultipleScenes else {
                throw IPadProbeFailure(message: "An iPad with multiple-scene support is required")
            }
            try await until("application active") { UIApplication.shared.applicationState == .active }
            for resolution in ["allow", "reject", "cancel"] {
                requestedDeferral = nil
                let id = UUID()
                guard case .applied = await store.perform(.openWindow(.init(id: id, route: .editor))) else {
                    throw IPadProbeFailure(message: "Open rejected")
                }
                try await until("native editor appears") { nativeScene(id) != nil && appeared[id, default: 0] > 0 }
                let deferralID = RouterDeferralID()
                requestedDeferral = deferralID
                let previousEntries = policyEntries
                let previousAppearances = appeared[id, default: 0]
                try closeNative(id)
                try await until("native closure enters policy") { policyEntries > previousEntries }
                try await until("canonical editor reopens") {
                    nativeScene(id) != nil && appeared[id, default: 0] > previousAppearances
                }
                guard store.state.windows.map(\.id) == [id] else {
                    throw IPadProbeFailure(message: "Deferred closure removed canonical editor")
                }
                log("NATIVE_REOPEN " + resolution)
                requestedDeferral = nil
                switch resolution {
                case "allow":
                    _ = await store.resolveDeferred(deferralID, with: .allow)
                    try await until("allow closes native and canonical editor") {
                        nativeScene(id) == nil && store.state.windows.isEmpty
                    }
                case "reject":
                    _ = await store.resolveDeferred(deferralID, with: .reject("Keep open"))
                    guard nativeScene(id) != nil, store.state.windows.map(\.id) == [id] else {
                        throw IPadProbeFailure(message: "Reject lost editor")
                    }
                default:
                    _ = await store.cancelDeferred(deferralID)
                    guard nativeScene(id) != nil, store.state.windows.map(\.id) == [id] else {
                        throw IPadProbeFailure(message: "Cancellation lost editor")
                    }
                }
                if !store.state.windows.isEmpty {
                    _ = await store.perform(.dismissWindow(id))
                    try await until("cleanup closes editor") { nativeScene(id) == nil && store.state.windows.isEmpty }
                }
                log("PASS " + resolution)
            }
            log("PASS native iPadOS allow/reject/cancel")
            exit(0)
        } catch {
            log("FAIL " + String(describing: error))
            exit(1)
        }
    }
}

private struct IPadProbeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct ProbeSceneCapture: UIViewRepresentable {
    let id: UUID
    let model: IPadProbeModel
    func makeUIView(context: Context) -> CaptureView { CaptureView(id: id, model: model) }
    func updateUIView(_ uiView: CaptureView, context: Context) {}

    final class CaptureView: UIView {
        let id: UUID
        weak var model: IPadProbeModel?
        init(id: UUID, model: IPadProbeModel) {
            self.id = id
            self.model = model
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { model?.attach(scene, to: id) }
        }
    }
}

@main
struct IPadProbeApp: App {
    @State private var model = IPadProbeModel()
    var body: some Scene {
        WindowGroup("Router Native Probe", id: "controller") {
            RouterSceneDriver(store: model.store, onEvent: { model.log("DRIVER " + String(describing: $0)) }) {
                Text(model.status).padding().task { await model.run() }
            }
        }
        WindowGroup("Probe Editor", id: "editor", for: UUID.self) { $id in
            if let id {
                RouterWindowHost(id: id, store: model.store)
                    .background(ProbeSceneCapture(id: id, model: model))
                    .onAppear {
                        model.appeared[id, default: 0] += 1
                        model.log("HOST_APPEAR " + id.uuidString)
                    }
            }
        }
    }
}
#endif
