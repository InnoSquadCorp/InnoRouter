import SwiftUI
import InnoRouter

private enum WatchProbeRoute: DestinationRoute {
    case root
    @MainActor static func destination(for route: Self) -> some View { Text("Root") }
}

@MainActor
@Observable
private final class WatchProbeModel {
    let creation: Result<RouterStore<WatchProbeRoute>, any Error>
    var result = "Ready"

    init() {
        do {
            creation = .success(try RouterStore(configuration: .init(hostDescriptor: .init(
                root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
            ))))
        } catch { creation = .failure(error) }
    }

    func show(_ store: RouterStore<WatchProbeRoute>, dialog: Bool, cancel: Bool = true) {
        result = "Waiting"
        var actions: [RouterPresentationAction<Bool>] = [.init(id: "accept", label: "Accept", value: true)]
        if cancel { actions.append(.init(id: "cancel", label: "Cancel", role: .cancel, value: false)) }
        let request: RouterTransientPresentationRequest<Bool> = dialog
            ? .confirmationDialog(title: "Router dialog", actions: actions)
            : .alert(title: "Router alert", actions: actions)
        Task {
            switch await store.scope().present(request) {
            case .value(let value): result = "value \(value)"
            case .dismissed: result = "dismissed"
            case .cancelled: result = "cancelled"
            case .rejected: result = "rejected"
            }
            print("WATCH_TRANSIENT_RESULT \(result)")
        }
    }
}

@main
struct RouterWatchTransientProbeApp: App {
    @State private var model = WatchProbeModel()
    var body: some Scene {
        WindowGroup {
            switch model.creation {
            case .success(let store):
                RouterHost(store: store) {
                    VStack(spacing: 4) {
                        Text(model.result).accessibilityIdentifier("watch.result")
                        Button("Alert") { model.show(store, dialog: false) }
                        Button("Dialog") { model.show(store, dialog: true) }
                        Button("No Cancel") { model.show(store, dialog: true, cancel: false) }
                    }.font(.caption)
                }
            case .failure:
                Text("Probe initialization failed")
            }
        }
    }
}
