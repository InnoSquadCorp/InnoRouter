import AppKit
import SwiftUI
import InnoRouter

@Router
enum ProbeRoute {
    @Scene(.window, id: "editor")
    case editor

    var destination: some View { Text("Native editor").frame(width: 300, height: 200) }
}

@MainActor
@Observable
final class ProbeModel {
    var status = "Starting"
    var requestedDeferral: RouterDeferralID?
    var policyEntries = 0
    var didRun = false
    var appeared: [UUID: Int] = [:]
    @ObservationIgnored lazy var store = RouterStore<ProbeRoute>(configuration: .init(policies: [
        RouterPolicy(name: "confirm-native-close") { [weak self] transition in
            if case .dismissWindow = transition.action, let self, let id = self.requestedDeferral {
                self.policyEntries += 1
                self.log("POLICY native close " + String(self.policyEntries))
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                log("WINDOWS " + NSApplication.shared.windows.map {
                    "title=\($0.title) visible=\($0.isVisible) id=\($0.identifier?.rawValue ?? "nil")"
                }.joined(separator: "; "))
                throw ProbeFailure(message: "Timeout: " + label + "; canonical=" + String(store.state.windows.count)
                    + "; native=" + String(editors.count) + "; revision=" + String(store.revision))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    var editors: [NSWindow] {
        NSApplication.shared.windows.filter { $0.title == "Probe Editor" && $0.isVisible }
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        do {
            for resolution in ["allow", "reject", "cancel"] {
                requestedDeferral = nil
                let id = UUID()
                let opening = await store.perform(.openWindow(.init(id: id, route: .editor)))
                guard case .applied = opening else { throw ProbeFailure(message: "Open rejected") }
                try await until("native editor appears") { editors.count == 1 && appeared[id, default: 0] > 0 }
                let deferralID = RouterDeferralID()
                requestedDeferral = deferralID
                let previousEntries = policyEntries
                let previousAppearances = appeared[id, default: 0]
                // Do not retain a closed NSWindow across the restoration wait.
                editors.first?.performClose(nil)
                log("NATIVE_CLOSE")
                try await until("system close enters policy") { policyEntries > previousEntries }
                try await until("canonical editor reopens") {
                    editors.count == 1 && appeared[id, default: 0] > previousAppearances
                }
                guard store.state.windows.map(\.id) == [id] else {
                    throw ProbeFailure(message: "Deferred close removed canonical editor")
                }
                log("NATIVE_REOPEN " + resolution)
                requestedDeferral = nil
                switch resolution {
                case "allow":
                    _ = await store.resolveDeferred(deferralID, with: .allow)
                    try await until("allow closes native and canonical editor") {
                        editors.isEmpty && store.state.windows.isEmpty
                    }
                case "reject":
                    _ = await store.resolveDeferred(deferralID, with: .reject("Keep open"))
                    guard editors.count == 1, store.state.windows.map(\.id) == [id] else {
                        throw ProbeFailure(message: "Reject lost editor")
                    }
                default:
                    _ = await store.cancelDeferred(deferralID)
                    guard editors.count == 1, store.state.windows.map(\.id) == [id] else {
                        throw ProbeFailure(message: "Cancel lost editor")
                    }
                }
                if !store.state.windows.isEmpty {
                    let closing = await store.perform(.dismissWindow(id))
                    log("CLEANUP " + String(describing: closing))
                    try await until("cleanup closes editor") { editors.isEmpty && store.state.windows.isEmpty }
                }
                log("PASS " + resolution)
            }
            log("PASS native macOS allow/reject/cancel")
        } catch {
            log("FAIL " + String(describing: error))
        }
        NSApplication.shared.terminate(nil)
    }
}

struct ProbeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@main
struct ProbeApp: App {
    @State private var model = ProbeModel()
    var body: some Scene {
        WindowGroup("Router Native Probe", id: "controller") {
            RouterSceneDriver(store: model.store, onEvent: { model.log("DRIVER " + String(describing: $0)) }) {
                Text(model.status).padding().frame(minWidth: 400, minHeight: 200)
                    .task { await model.run() }
            }
        }
        .restorationBehavior(.disabled)
        WindowGroup("Probe Editor", id: "editor", for: UUID.self) { $id in
            if let id {
                RouterWindowHost(id: id, store: model.store)
                    .onAppear {
                        model.appeared[id, default: 0] += 1
                        model.log("HOST_APPEAR " + id.uuidString)
                    }
                    .onDisappear { model.log("HOST_DISAPPEAR " + id.uuidString) }
            }
        }
        .restorationBehavior(.disabled)
    }
}
