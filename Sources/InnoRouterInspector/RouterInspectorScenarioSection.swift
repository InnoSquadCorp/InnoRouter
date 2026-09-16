import Foundation
import SwiftUI
#if os(iOS) || os(macOS) || os(visionOS)
import UniformTypeIdentifiers
#endif

@MainActor
struct RouterInspectorScenarioSection: View {
    @Environment(\.locale) private var locale
    @Bindable var controller: RouterInspectorScenarioController
#if os(iOS) || os(macOS) || os(visionOS)
    @State private var isImportingRawFixture = false
#endif

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: routerInspectorLocalized("Recording status", locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: routerInspectorLocalized(controller.status.rawValue, locale: locale))
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            ProgressView(
                value: Double(controller.capturedStepCount),
                total: Double(controller.capacity)
            )
            .accessibilityLabel(Text(verbatim: routerInspectorLocalized("Recording progress", locale: locale)))
            if let failure = controller.failure {
                Text(verbatim: routerInspectorLocalized(failure.localizationKey, locale: locale))
                    .font(.caption)
            } else if !controller.summary.isEmpty {
                Text(verbatim: controller.summary)
                    .font(.caption.monospaced())
            }
            Group {
                if controller.status == .recording {
                    Button(routerInspectorLocalized("Refresh progress", locale: locale)) {
                        controller.refreshProgress()
                    }
                    Button(routerInspectorLocalized("Stop recording", locale: locale)) {
                        controller.stop()
                    }
                    Button(role: .cancel) {
                        controller.cancel()
                    } label: {
                        Text(verbatim: routerInspectorLocalized("Cancel recording", locale: locale))
                    }
                } else {
                    Button(routerInspectorLocalized("Start recording", locale: locale)) {
                        controller.start()
                    }
                }
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
#if os(iOS) || os(macOS) || os(visionOS)
            if controller.canImportRawFixture && controller.status != .recording {
                Button {
                    isImportingRawFixture = true
                } label: {
                    Label(
                        routerInspectorLocalized("Import raw fixture", locale: locale),
                        systemImage: "square.and.arrow.down"
                    )
                }
            }
            if let data = controller.rawExportData() {
                Text(verbatim: routerInspectorLocalized("Raw fixture may contain route payloads", locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShareLink(item: String(decoding: data, as: UTF8.self)) {
                    Label(
                        routerInspectorLocalized("Export raw fixture", locale: locale),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
#endif
        } header: {
            Text(verbatim: routerInspectorLocalized("Scenario recording", locale: locale))
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
