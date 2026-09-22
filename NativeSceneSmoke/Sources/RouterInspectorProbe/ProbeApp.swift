#if os(macOS)
import AppKit
#endif
import SwiftUI
import InnoRouter
import InnoRouterInspector
import InnoRouterTesting

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
enum InspectorProbeRoute: Codable {
    @DeepLink("/products/:id")
    case product(id: String)
    @DeepLink("/settings")
    case settings

    var destination: some View { Text("Probe destination") }
}

@MainActor
@Observable
final class InspectorProbeModel {
    var holdsExecution = false
    var policyEntries = 0
    var exportStatus = "Not exported"
    let recorder = RouterInspectorRecorder()
    @ObservationIgnored var subscription: RouterInspectorSubscription?
    @ObservationIgnored lazy var store = makeStore()
    @ObservationIgnored lazy var scenario = RouterInspectorScenarioController.routerScenario(store: store)

    private func makeStore() -> RouterStore<InspectorProbeRoute> {
        let policy = RouterPolicy<InspectorProbeRoute>(name: "probe-policy") { [weak self] _ in
            guard let self else { return .allow }
            policyEntries += 1
            if holdsExecution { try? await Task.sleep(for: .seconds(300)) }
            return .allow
        }
        return RouterStore(configuration: .init(policies: [policy]))
    }

    func start() {
        guard subscription == nil else { return }
        subscription = recorder.attach(to: store)
    }

    func checkRedaction() {
        do {
            let data = try recorder.encodedSnapshot()
            let clean = !String(decoding: data, as: UTF8.self).contains("private-payload-600")
            exportStatus = clean ? "PASS redacted export" : "FAIL payload leaked"
        } catch { exportStatus = "FAIL export" }
        FileHandle.standardOutput.write(Data((exportStatus + "\n").utf8))
    }
}

@MainActor
private struct InspectorProbeRoot: View {
    @Environment(\.locale) private var inheritedLocale
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @State private var probeLocale = "en"
    @Bindable var model: InspectorProbeModel
    private let isLocalizationProbe = ProcessInfo.processInfo.arguments.contains("--localization-probe")

    var body: some View {
        VStack {
            if isLocalizationProbe {
                InspectorProbeLocaleControls(localeIdentifier: $probeLocale)
            }
            InspectorProbeControls(model: model)
            TabView {
                NavigationStack {
                    RouterInspectorDeepLinkView(
                        store: model.store,
                        initialURL: "probe://app/products/private-payload-600"
                    )
                }
                .environment(\.locale, isLocalizationProbe ? Locale(identifier: probeLocale) : inheritedLocale)
                .environment(
                    \.layoutDirection,
                    isLocalizationProbe ? (probeLocale == "ar" ? .rightToLeft : .leftToRight) : inheritedLayoutDirection
                )
                .tabItem { Text("Deep links") }
                RouterInspectorView(recorder: model.recorder, scenario: model.scenario)
                    .environment(\.locale, isLocalizationProbe ? Locale(identifier: probeLocale) : inheritedLocale)
                    .environment(
                        \.layoutDirection,
                        isLocalizationProbe ? (probeLocale == "ar" ? .rightToLeft : .leftToRight) : inheritedLayoutDirection
                    )
                    .tabItem { Text("Timeline") }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 650)
        #endif
        .task {
            model.start()
            #if os(macOS)
            NSApp.activate(ignoringOtherApps: true)
            #endif
        }
    }
}

@MainActor
private struct InspectorProbeLocaleControls: View {
    @Binding var localeIdentifier: String

    var body: some View {
        HStack {
            Button("en") { localeIdentifier = "en" }
                .accessibilityIdentifier("probe.locale.en")
            Button("ko") { localeIdentifier = "ko" }
                .accessibilityIdentifier("probe.locale.ko")
            Button("de") { localeIdentifier = "de" }
                .accessibilityIdentifier("probe.locale.de")
            Button("ar") { localeIdentifier = "ar" }
                .accessibilityIdentifier("probe.locale.ar")
            Text(verbatim: "Locale \(localeIdentifier)")
                .accessibilityIdentifier("probe.locale.current")
        }
        .buttonStyle(.bordered)
    }
}

@MainActor
private struct InspectorProbeControls: View {
    @Bindable var model: InspectorProbeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Revision \(model.store.revision) · Policy \(model.policyEntries)")
                .accessibilityIdentifier("probe.revision-policy")
            HStack {
                Button("Hold execution") { model.holdsExecution = true }
                    .accessibilityIdentifier("probe.execution.hold")
                Button("Resume execution") { model.holdsExecution = false }
                    .accessibilityIdentifier("probe.execution.resume")
                Text(model.holdsExecution ? "Execution held" : "Execution ready")
                    .accessibilityIdentifier("probe.execution.state")
            }
            Button("Check redacted export") { model.checkRedaction() }
            Text(model.exportStatus)
        }
        .padding()
    }
}

@main
struct InspectorProbeApp: App {
    @State private var model = InspectorProbeModel()
    var body: some Scene {
        WindowGroup("Router Inspector Probe") { InspectorProbeRoot(model: model) }
            #if os(macOS)
            .restorationBehavior(.disabled)
            #endif
    }
}
