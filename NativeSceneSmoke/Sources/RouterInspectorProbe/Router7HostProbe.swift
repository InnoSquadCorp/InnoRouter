import Foundation
import SwiftUI
import InnoRouter

// UI-only fixture. Every rendered host below uses the same Store authority.
@Router
enum HostProbeRoute: Codable {
    @TabItem("Home", systemImage: "house") case home
    @TabItem("Settings", systemImage: "gear") case settings
    case detail(name: String)
    @PresentationResult(Bool.self) case outer
    @PresentationResult(Bool.self) case inner

    @ViewBuilder var destination: some View {
        switch self {
        case .home: HostProbeActions(title: "Home root")
        case .settings: HostProbeActions(title: "Settings root")
        case .detail(let name): HostProbeDetail(name: name)
        case .outer: HostProbeModal(isInner: false)
        case .inner: HostProbeModal(isInner: true)
        }
    }
}

@MainActor @Observable
final class HostProbeModel {
    let store: RouterStore<HostProbeRoute>
    let catalog: RouterTabCatalog<HostProbeRoute>
    let codec: RouterSnapshotCodec<HostProbeRoute>
    var mode = "tabs"
    var status = "Ready"
    var outerResult = "Outer idle"
    var innerResult = "Inner idle"
    var transientResult = "Transient idle"
    @ObservationIgnored var savedActions: RouterActions<HostProbeRoute>?
    @ObservationIgnored var savedModalActions: RouterActions<HostProbeRoute>?
    @ObservationIgnored var outerTask: Task<Void, Never>?

    init() throws {
        catalog = try RouterTabCatalog(HostProbeRoute.routerTabs)
        codec = try RouterSnapshotCodec(currentVersion: 1)
        store = try HostProbeRoute.makeRouterStore(initialState: Self.tabsState(), configuration: .init(hostDescriptor: catalog.hostDescriptor()))
    }

    static func tabsState() throws -> RouterState<HostProbeRoute> {
        try .init(root: .container(.init(style: .tabs, selection: "home", branches: [.init(id: "home"), .init(id: "settings")])))
    }

    var snapshotURL: URL { URL.documentsDirectory.appending(path: "router7-ui-snapshot.json") }

    func replace(with newMode: String) async {
        do {
            let state: RouterState<HostProbeRoute>
            let descriptor: RouterHostDescriptor<HostProbeRoute>
            if newMode == "tabs" {
                state = try Self.tabsState()
                descriptor = catalog.hostDescriptor()
            } else {
                let layout = RouterTwoColumnSplitLayout.standard
                state = try .init(root: .container(.init(style: .split, selection: "detail", branches: [.init(id: "sidebar"), .init(id: "detail")], split: .init(visibility: .all))))
                descriptor = .init(root: layout.hostShape, rootDeclarations: layout.hostRootDeclarations(for: HostProbeRoute.self, sidebarDeclarationID: "probe.sidebar", detailDeclarationID: "probe.detail"))
            }
            let outcome = await store.replaceHost(with: .init(state: state), descriptor: descriptor)
            if case .applied = outcome { mode = newMode }
            report("Replace \(newMode): \(Self.describe(outcome))")
        } catch { report("ERROR \(error)") }
    }

    func save() async {
        do {
            let data = try await store.snapshot(using: codec)
            let url = snapshotURL
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            report("Snapshot saved")
        } catch { report("ERROR save \(error)") }
    }

    func restore() async {
        do {
            let url = snapshotURL
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let result = try await store.restore(from: data, using: codec)
            report("Snapshot restored: \(Self.describe(result))")
        } catch { report("ERROR restore \(error)") }
    }

    func startOuter(using router: RouterActions<HostProbeRoute>) {
        outerResult = "Outer waiting"
        innerResult = "Inner idle"
        outerTask = Task { [weak self] in
            let outcome = await router.present(HostProbeRoute.Presentation.outer)
            self?.outerResult = "Outer \(Self.describe(outcome))"
            self?.report(self?.outerResult ?? "Outer ended")
        }
    }

    func replayOldScope() async {
        guard let savedActions else { report("ERROR no old scope"); return }
        let before = store.state
        let revision = store.revision
        let outcome = await savedActions.perform(.push(.detail(name: "STALE")))
        report("Old scope: \(Self.describe(outcome)); unchanged \(before == store.state && revision == store.revision)")
    }

    func replayOldModal() async {
        guard let savedModalActions else { report("ERROR no old modal"); return }
        let before = store.state
        let revision = store.revision
        let outcome = await savedModalActions.dismiss().value
        report("Old callback: \(Self.describe(outcome)); unchanged \(before == store.state && revision == store.revision)")
    }

    func report(_ value: String) { status = value; print("ROUTER7_UI \(value) revision=\(store.revision)") }

    static func describe(_ outcome: RouterOutcome<HostProbeRoute>) -> String {
        switch outcome {
        case .applied: "applied"
        case .unchanged: "unchanged"
        case .deferred: "deferred"
        case .rejected: "rejected"
        }
    }
    static func describe(_ outcome: RouterPresentationOutcome<Bool>) -> String {
        switch outcome {
        case .value(let value): "value \(value)"
        case .dismissed: "dismissed"
        case .cancelled: "cancelled"
        case .rejected: "rejected"
        }
    }
}

@MainActor
struct Router7HostProbe: View {
    @State private var model: HostProbeModel?
    @State private var setupError: String?
    var body: some View {
        Group {
            if let model {
                VStack(spacing: 8) {
                    HostProbeOwnerControls(model: model)
                    HostProbeSurface(model: model)
                }
                .environment(model)
            } else if let setupError {
                Text("ERROR setup \(setupError)")
            } else { ProgressView("Preparing Router 7") }
        }
        .task {
            guard model == nil else { return }
            do { model = try HostProbeModel() }
            catch { setupError = String(describing: error) }
        }
    }
}

@MainActor
private struct HostProbeOwnerControls: View {
    let model: HostProbeModel
    var body: some View {
        VStack(spacing: 6) {
            Text("Router 7 · \(model.mode) · revision \(model.store.revision)").accessibilityIdentifier("host.mode")
            HStack {
                Button("Tabs") { Task { await model.replace(with: "tabs") } }.accessibilityIdentifier("host.tabs")
                Button("Split") { Task { await model.replace(with: "split") } }.accessibilityIdentifier("host.split")
                Button("Save") { Task { await model.save() } }.accessibilityIdentifier("host.save")
                Button("Restore") { Task { await model.restore() } }.accessibilityIdentifier("host.restore")
                Button("Old scope") { Task { await model.replayOldScope() } }.accessibilityIdentifier("host.old-scope")
            }
            .buttonStyle(.bordered)
            Text(model.status).accessibilityIdentifier("host.status")
            Text(model.outerResult).accessibilityIdentifier("host.outer-result")
        }
        .font(.footnote)
        .padding(.horizontal)
    }
}

@MainActor
private struct HostProbeSurface: View {
    let model: HostProbeModel
    var body: some View {
        if model.mode == "tabs" {
            switch Result(catching: { try RouterTabHost(store: model.store, catalog: model.catalog) }) {
            case .success(let host): host
            case .failure(let error): Text("ERROR tabs \(String(describing: error))")
            }
        } else {
            switch Result(catching: {
                try RouterSplitHost(store: model.store, sidebarDeclarationID: "probe.sidebar", detailDeclarationID: "probe.detail") {
                    HostProbeSidebar()
                } root: { HostProbeActions(title: "Split detail root") }
            }) {
            case .success(let host): host
            case .failure(let error): Text("ERROR split \(String(describing: error))")
            }
        }
    }
}

@MainActor
private struct HostProbeSidebar: View {
    @EnvironmentRouter(HostProbeRoute.self) private var router
    var body: some View {
        VStack(spacing: 18) {
            Text("Split sidebar").accessibilityIdentifier("host.sidebar")
            Button("Sidebar detail") { router.go(.detail(name: "Sidebar")) }.accessibilityIdentifier("host.sidebar-detail")
        }
        .navigationTitle("Sidebar")
    }
}

@MainActor
private struct HostProbeActions: View {
    let title: String
    @Environment(HostProbeModel.self) private var model
    @EnvironmentRouter(HostProbeRoute.self) private var router
    var body: some View {
        VStack(spacing: 18) {
            Text(title).accessibilityIdentifier("host.root")
            Button("Open detail") { router.go(.detail(name: title)) }.accessibilityIdentifier("host.open-detail")
            Button("Open outer") { model.startOuter(using: router) }.accessibilityIdentifier("host.open-outer")
            Button("Capture scope") { model.savedActions = router; model.report("Scope captured") }.accessibilityIdentifier("host.capture-scope")
            HostProbeTransientControls()
        }
        .buttonStyle(.bordered)
        .navigationTitle(title)
    }
}

@MainActor
private struct HostProbeDetail: View {
    let name: String
    @EnvironmentRouter(HostProbeRoute.self) private var router
    var body: some View {
        VStack(spacing: 18) {
            Text("Detail \(name)").accessibilityIdentifier("host.detail")
            Button("Back to root") { router.backToRoot() }.accessibilityIdentifier("host.back-root")
        }
        .navigationTitle("Saved detail")
    }
}

@MainActor
private struct HostProbeTransientControls: View {
    var scopeID = "host"
    @Environment(HostProbeModel.self) private var model
    @EnvironmentRouter(HostProbeRoute.self) private var router
    var body: some View {
        VStack(spacing: 12) {
            Button("Show alert") {
                Task {
                    model.transientResult = "Alert \(HostProbeModel.describe(await router.present(.alert(title: "Router alert", message: "Native alert in this scope", actions: [.init(id: "accept", label: "Accept alert", value: true), .init(id: "cancel", label: "Cancel alert", role: .cancel, value: false)]))))"
                }
            }.accessibilityIdentifier("\(scopeID).alert")
            Button("Show dialog") {
                Task {
                    model.transientResult = "Dialog \(HostProbeModel.describe(await router.present(.confirmationDialog(title: "Router dialog", actions: [.init(id: "accept", label: "Accept dialog", value: true), .init(id: "cancel", label: "Cancel dialog", role: .cancel, value: false)]))))"
                }
            }.accessibilityIdentifier("\(scopeID).dialog")
            Text(model.transientResult).accessibilityIdentifier("\(scopeID).transient-result")
        }
    }
}

@MainActor
private struct HostProbeModal: View {
    let isInner: Bool
    @Environment(HostProbeModel.self) private var model
    @EnvironmentRouter(HostProbeRoute.self) private var router
    var body: some View {
        VStack(spacing: 14) {
            Text(isInner ? "Inner modal" : "Outer modal").accessibilityIdentifier("host.modal-title")
            if !isInner {
                Button("Open inner") {
                    Task { model.innerResult = "Inner \(HostProbeModel.describe(await router.present(HostProbeRoute.Presentation.inner)))" }
                }.accessibilityIdentifier("host.open-inner")
                Text(model.innerResult).accessibilityIdentifier("host.inner-result")
                Button("Capture modal callback") { model.savedModalActions = router; model.report("Modal captured") }.accessibilityIdentifier("host.capture-modal")
                Button("Replay old callback") { Task { await model.replayOldModal() } }.accessibilityIdentifier("host.old-modal")
                Text(model.status).accessibilityIdentifier("host.modal-status")
                Button("Cancel waiter") { model.outerTask?.cancel() }.accessibilityIdentifier("host.cancel-waiter")
            }
            HostProbeTransientControls(scopeID: isInner ? "inner" : "outer")
            Button("Finish value") {
                Task {
                    do { try await router.finishPresentation(isInner ? HostProbeRoute.Presentation.inner : HostProbeRoute.Presentation.outer, returning: true) }
                    catch { model.report("ERROR finish \(error)") }
                }
            }.accessibilityIdentifier("host.finish")
            Button("Close modal") { router.dismiss() }.accessibilityIdentifier("host.close")
        }
        .buttonStyle(.bordered)
        .padding()
        .navigationTitle(isInner ? "Inner" : "Outer")
    }
}
