import Foundation
import SwiftUI
#if os(iOS) || os(macOS) || os(visionOS)
import UniformTypeIdentifiers
#endif

@MainActor
struct RouterInspectorScenarioSection: View {
    @Bindable var controller: RouterInspectorScenarioController
#if os(iOS) || os(macOS) || os(visionOS)
    @State private var isImportingRawFixture = false
#endif

    var body: some View {
        Section {
            LabeledContent(routerInspectorLocalized("Recording status")) {
                Text(verbatim: routerInspectorLocalized(controller.status.rawValue))
            }
            ProgressView(
                value: Double(controller.capturedStepCount),
                total: Double(controller.capacity)
            )
            .accessibilityLabel(Text(verbatim: routerInspectorLocalized("Recording progress")))
            if !controller.summary.isEmpty {
                Text(verbatim: controller.summary)
                    .font(.caption.monospaced())
            }
            HStack {
                if controller.status == .recording {
                    Button(routerInspectorLocalized("Refresh progress")) {
                        controller.refreshProgress()
                    }
                    Button(routerInspectorLocalized("Stop recording")) {
                        controller.stop()
                    }
                    Button(role: .cancel) {
                        controller.cancel()
                    } label: {
                        Text(verbatim: routerInspectorLocalized("Cancel recording"))
                    }
                } else {
                    Button(routerInspectorLocalized("Start recording")) {
                        controller.start()
                    }
                }
            }
#if os(iOS) || os(macOS) || os(visionOS)
            if controller.canImportRawFixture && controller.status != .recording {
                Button {
                    isImportingRawFixture = true
                } label: {
                    Label(
                        routerInspectorLocalized("Import raw fixture"),
                        systemImage: "square.and.arrow.down"
                    )
                }
            }
            if let data = controller.rawExportData() {
                Text(verbatim: routerInspectorLocalized("Raw fixture may contain route payloads"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShareLink(item: String(decoding: data, as: UTF8.self)) {
                    Label(
                        routerInspectorLocalized("Export raw fixture"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
#endif
        } header: {
            Text(verbatim: routerInspectorLocalized("Scenario recording"))
        }
#if os(iOS) || os(macOS) || os(visionOS)
        .fileImporter(
            isPresented: $isImportingRawFixture,
            allowedContentTypes: [.json]
        ) { result in
            Task { @MainActor in
                guard let url = try? result.get() else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
                controller.importRawFixture(data)
            }
        }
#endif
    }
}
