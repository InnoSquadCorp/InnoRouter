import SwiftUI
#if os(iOS) || os(macOS) || os(visionOS)
import UniformTypeIdentifiers
#endif

/// A native developer-facing timeline for ``RouterInspectorRecorder``.
@MainActor
public struct RouterInspectorView: View {
    @Environment(\.locale) private var locale
#if !os(watchOS)
    @Environment(\.layoutDirection) private var layoutDirection
#endif
    @Bindable private var recorder: RouterInspectorRecorder
    private let scenario: RouterInspectorScenarioController?
    @State private var timeline = RouterInspectorTimeline()
    @State private var comparisonEntryID: RouterInspectorEntry.ID?
#if os(iOS) || os(macOS) || os(visionOS)
    @State private var isImporting = false
    @State private var importFailed = false
#endif

    public init(
        recorder: RouterInspectorRecorder,
        scenario: RouterInspectorScenarioController? = nil
    ) {
        self.recorder = recorder
        self.scenario = scenario
    }

    public var body: some View {
#if os(watchOS)
        inspectorList
#else
        // Keep the Inspector's parent-facing identity stable (including an
        // implicitly selected TabView item) when the native boundary changes.
        ZStack {
            NavigationSplitView {
                inspectorList
                    .navigationTitle(Text(verbatim: routerInspectorLocalized("Inspector", locale: locale)))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
            } detail: {
                if let entry = timeline.selectedEntry {
                    RouterInspectorDetail(
                        entry: entry,
                        comparison: selectedComparison
                    )
                } else {
                    ContentUnavailableView(
                        label: {
                            Label {
                                Text(verbatim: routerInspectorLocalized("Select an event", locale: locale))
                            } icon: {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                            }
                        }
                    )
                }
            }
            // Native split/list containers can retain mirrored geometry after a
            // direction change. Recreate only that boundary; timeline, selection,
            // comparison, recorder, and scenario state stay owned outside it.
            .id(layoutDirection)
        }
#endif
    }

    private var filteredEntries: [RouterInspectorEntry] {
        timeline.filteredEntries
    }

    private var inspectorList: some View {
        List(selection: $timeline.selection) {
            if let scenario {
                RouterInspectorScenarioSection(controller: scenario)
            }
#if os(watchOS)
            Section {
                ForEach(RouterInspectorDomain.allCases) { domain in
                    Button {
                        timeline.toggleVisibility(of: domain)
                    } label: {
                        Label {
                            Text(verbatim: domain.rawValue)
                        } icon: {
                            Image(
                                systemName: timeline.visibleDomains.contains(domain)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                    }
                }
            } header: {
                Text(verbatim: routerInspectorLocalized("Domains", locale: locale))
            }
#endif

            if filteredEntries.isEmpty {
                Text(verbatim: routerInspectorLocalized(
                    recorder.entries.isEmpty ? "No events recorded" : "No matching events",
                    locale: locale
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inspector.timeline.empty")
            }
            ForEach(filteredEntries) { entry in
                RouterInspectorRow(
                    entry: entry,
                    isBookmarked: recorder.isBookmarked(entry.id)
                )
                    .tag(entry.id)
            }
        }
        .onChange(of: recorder.entries, initial: true) { _, entries in
            timeline.updateEntries(entries)
        }
        .searchable(
            text: $timeline.searchText,
            prompt: Text(verbatim: routerInspectorLocalized("Filter events", locale: locale))
        )
        .toolbar {
            ToolbarItemGroup {
                #if !os(watchOS)
                Menu {
                    ForEach(RouterInspectorDomain.allCases) { domain in
                        Button {
                            timeline.toggleVisibility(of: domain)
                        } label: {
                            Label {
                                Text(verbatim: domain.rawValue)
                            } icon: {
                                Image(
                                    systemName: timeline.visibleDomains.contains(domain)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                        }
                    }
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Domains", locale: locale))
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                #endif

                Button {
                    recorder.isPaused ? recorder.resume() : recorder.pause()
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized(recorder.isPaused ? "Resume" : "Pause", locale: locale))
                    } icon: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    }
                }

                Button {
                    recorder.setPauseOnRejection(!recorder.pauseOnRejection)
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Pause on rejection", locale: locale))
                    } icon: {
                        Image(
                            systemName: recorder.pauseOnRejection
                                ? "exclamationmark.octagon.fill"
                                : "exclamationmark.octagon"
                        )
                    }
                }

                Button {
                    if let selection = timeline.selectedEntry?.id { recorder.toggleBookmark(selection) }
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Bookmark", locale: locale))
                    } icon: {
                        Image(
                            systemName: timeline.selectedEntry.map { recorder.isBookmarked($0.id) } == true
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                }
                .disabled(timeline.selectedEntry == nil)

                Button {
                    comparisonEntryID = timeline.selectedEntry?.id
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Set comparison baseline", locale: locale))
                    } icon: {
                        Image(systemName: "arrow.left.and.right")
                    }
                }
                .disabled(timeline.selectedEntry == nil)

                Button {
                    timeline.stepSelection(by: -1)
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Previous event", locale: locale))
                    } icon: {
                        Image(systemName: "chevron.up")
                    }
                }
                .disabled(!timeline.canStepSelection(by: -1))

                Button {
                    timeline.stepSelection(by: 1)
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Next event", locale: locale))
                    } icon: {
                        Image(systemName: "chevron.down")
                    }
                }
                .disabled(!timeline.canStepSelection(by: 1))

                Button {
                    timeline.selection = nil
                    comparisonEntryID = nil
                    recorder.clear()
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Clear", locale: locale))
                    } icon: {
                        Image(systemName: "trash")
                    }
                }

#if os(iOS) || os(macOS) || os(visionOS)
                Button {
                    isImporting = true
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Import", locale: locale))
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }

                ShareLink(item: exportText) {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Export", locale: locale))
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
#endif
            }
        }
#if os(iOS) || os(macOS) || os(visionOS)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json]
        ) { result in
            importSnapshot(result)
        }
        .alert(
            Text(verbatim: routerInspectorLocalized("Import failed", locale: locale)),
            isPresented: Binding(
                get: { importFailed },
                set: { importFailed = $0 }
            )
        ) {
            Button(routerInspectorLocalized("OK", locale: locale)) { importFailed = false }
        } message: {
            Text(verbatim: routerInspectorLocalized("Unknown error", locale: locale))
        }
#endif
    }

    private var exportText: String {
        guard let data = try? recorder.encodedDiagnosticBundle() else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var selectedComparison: RouterInspectorStateDiff? {
        let selection = timeline.selectedEntry?.id
        if let comparisonEntryID, let selection {
            return recorder.comparison(from: comparisonEntryID, to: selection)
        }
        guard let selection,
              let index = recorder.entries.firstIndex(where: { $0.id == selection }),
              let current = recorder.entries[index].state,
              index > recorder.entries.startIndex else {
            return nil
        }
        for previousIndex in recorder.entries.indices[..<index].reversed() {
            if let previous = recorder.entries[previousIndex].state {
                return RouterInspectorProjection.diff(from: previous, to: current)
            }
        }
        return nil
    }

#if os(iOS) || os(macOS) || os(visionOS)
    private func importSnapshot(_ result: Result<URL, any Error>) {
        Task { @MainActor in
            do {
                let url = try result.get()
                let maximumByteCount = recorder.importLimits.maximumEncodedByteCount
                let data = try await Task.detached {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    if let fileSize = values.fileSize, fileSize > maximumByteCount {
                        throw RouterInspectorImportError.encodedDataTooLarge(
                            actualByteCount: fileSize,
                            maximumByteCount: maximumByteCount
                        )
                    }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                if try RouterInspectorImportPreflight.isDiagnosticBundle(data, limits: recorder.importLimits) {
                    try recorder.importDiagnosticBundle(from: data)
                } else {
                    try recorder.importSnapshot(from: data)
                }
                timeline.updateEntries(recorder.entries)
                timeline.selection = filteredEntries.first?.id
                comparisonEntryID = nil
            } catch {
                importFailed = true
            }
        }
    }
#endif
}

private struct RouterInspectorRow: View {
    @Environment(\.locale) private var locale
    let entry: RouterInspectorEntry
    let isBookmarked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: entry.domain.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: entry.outcome.rawValue)
                    .font(.caption)
            }
            Text(verbatim: entry.name)
                .font(.body.monospaced())
            if isBookmarked {
                Label {
                    Text(verbatim: routerInspectorLocalized("Bookmarked", locale: locale))
                } icon: {
                    Image(systemName: "bookmark.fill")
                }
                .font(.caption)
            }
            Text(entry.timestamp, format: .dateTime.hour().minute().second().locale(locale))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct RouterInspectorDetail: View {
    @Environment(\.locale) private var locale
    let entry: RouterInspectorEntry
    let comparison: RouterInspectorStateDiff?

    var body: some View {
        Form {
            LabeledContent {
                Text(verbatim: entry.domain.rawValue)
            } label: {
                Text(verbatim: routerInspectorLocalized("Domain", locale: locale))
            }
            LabeledContent {
                Text(verbatim: entry.name)
            } label: {
                Text(verbatim: routerInspectorLocalized("Event", locale: locale))
            }
            LabeledContent {
                Text(verbatim: entry.outcome.rawValue)
            } label: {
                Text(verbatim: routerInspectorLocalized("Outcome", locale: locale))
            }
            ForEach(entry.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                LabeledContent {
                    Text(verbatim: item.value)
                } label: {
                    Text(verbatim: item.key)
                }
            }
            if let replay = entry.replay {
                Section {
                    LabeledContent {
                        Text(verbatim: replay.status.rawValue)
                    } label: {
                        Text(verbatim: routerInspectorLocalized("Pure reducer", locale: locale))
                    }
                    if let error = replay.error {
                        LabeledContent {
                            Text(verbatim: error)
                        } label: {
                            Text(verbatim: routerInspectorLocalized("Error", locale: locale))
                        }
                    }
                } header: {
                    Text(verbatim: routerInspectorLocalized("Replay preview", locale: locale))
                }
            }
            if let diff = entry.diff {
                Section {
                    if diff.changes.isEmpty {
                        Text(verbatim: routerInspectorLocalized("No structural changes", locale: locale))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(diff.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "\(change.path) · \(change.field)")
                                .font(.caption.monospaced())
                            Text(verbatim: "\(change.before) → \(change.after)")
                        }
                    }
                } header: {
                    Text(verbatim: routerInspectorLocalized("State diff", locale: locale))
                }
            }
            if entry.diff == nil, let comparison {
                Section {
                    if comparison.changes.isEmpty {
                        Text(verbatim: routerInspectorLocalized("No structural changes", locale: locale))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(comparison.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "\(change.path) · \(change.field)")
                                .font(.caption.monospaced())
                            Text(verbatim: "\(change.before) → \(change.after)")
                        }
                    }
                } header: {
                    Text(verbatim: routerInspectorLocalized("Previous captured state", locale: locale))
                }
            }
            if let state = entry.state {
                Section {
                    ForEach(state.flattenedNodes) { row in
                        RouterInspectorStateRow(row: row)
                    }
                } header: {
                    Text(verbatim: routerInspectorLocalized("State tree", locale: locale))
                }
            }
        }
        .navigationTitle(Text(verbatim: entry.name))
    }
}

private struct RouterInspectorStateRow: View {
    let row: RouterInspectorFlatNode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(String(repeating: "  ", count: row.depth))\(row.node.label)")
                .font(.body.monospaced())
            Text(
                verbatim: ([row.node.kind.rawValue] + row.node.details.sorted(by: { $0.key < $1.key }).map {
                    "\($0.key)=\($0.value)"
                }).joined(separator: " · ")
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }
}
