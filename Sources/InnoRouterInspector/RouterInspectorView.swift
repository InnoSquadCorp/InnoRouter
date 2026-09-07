import SwiftUI
#if os(iOS) || os(macOS) || os(visionOS)
import UniformTypeIdentifiers
#endif

/// A native developer-facing timeline for ``RouterInspectorRecorder``.
@MainActor
public struct RouterInspectorView: View {
    @Bindable private var recorder: RouterInspectorRecorder
    private let scenario: RouterInspectorScenarioController?
    @State private var selection: RouterInspectorEntry.ID?
    @State private var visibleDomains = Set(RouterInspectorDomain.allCases)
    @State private var searchText = ""
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
        NavigationSplitView {
            inspectorList
                .navigationTitle(Text(verbatim: routerInspectorLocalized("InnoRouter Inspector")))
        } detail: {
            if let entry = selectedEntry {
                RouterInspectorDetail(
                    entry: entry,
                    comparison: selectedComparison
                )
            } else {
                ContentUnavailableView(
                    label: {
                        Label {
                            Text(verbatim: routerInspectorLocalized("Select an event"))
                        } icon: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                        }
                    }
                )
            }
        }
#endif
    }

    private var filteredEntries: [RouterInspectorEntry] {
        recorder.entries.filter { entry in
            guard visibleDomains.contains(entry.domain) else { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.localizedLowercase
            return entry.name.localizedLowercase.contains(needle)
                || entry.domain.rawValue.localizedLowercase.contains(needle)
                || entry.outcome.rawValue.localizedLowercase.contains(needle)
                || entry.metadata.contains { key, value in
                    key.localizedLowercase.contains(needle)
                        || value.localizedLowercase.contains(needle)
                }
        }
    }

    private var selectedEntry: RouterInspectorEntry? {
        guard let selection else { return nil }
        return recorder.entries.first { $0.id == selection }
    }

    private var inspectorList: some View {
        List(selection: $selection) {
            if let scenario {
                RouterInspectorScenarioSection(controller: scenario)
            }
#if os(watchOS)
            Section {
                ForEach(RouterInspectorDomain.allCases) { domain in
                    Button {
                        toggleVisibility(of: domain)
                    } label: {
                        Label {
                            Text(verbatim: domain.rawValue)
                        } icon: {
                            Image(
                                systemName: visibleDomains.contains(domain)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                    }
                }
            } header: {
                Text(verbatim: routerInspectorLocalized("Domains"))
            }
#endif

            ForEach(filteredEntries) { entry in
                RouterInspectorRow(
                    entry: entry,
                    isBookmarked: recorder.isBookmarked(entry.id)
                )
                    .tag(entry.id)
            }
        }
        .searchable(
            text: $searchText,
            prompt: Text(verbatim: routerInspectorLocalized("Filter events"))
        )
        .toolbar {
            ToolbarItemGroup {
                #if !os(watchOS)
                Menu {
                    ForEach(RouterInspectorDomain.allCases) { domain in
                        Button {
                            toggleVisibility(of: domain)
                        } label: {
                            Label {
                                Text(verbatim: domain.rawValue)
                            } icon: {
                                Image(
                                    systemName: visibleDomains.contains(domain)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                        }
                    }
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Domains"))
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                #endif

                Button {
                    recorder.isPaused ? recorder.resume() : recorder.pause()
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized(recorder.isPaused ? "Resume" : "Pause"))
                    } icon: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    }
                }

                Button {
                    recorder.setPauseOnRejection(!recorder.pauseOnRejection)
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Pause on rejection"))
                    } icon: {
                        Image(
                            systemName: recorder.pauseOnRejection
                                ? "exclamationmark.octagon.fill"
                                : "exclamationmark.octagon"
                        )
                    }
                }

                Button {
                    if let selection { recorder.toggleBookmark(selection) }
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Bookmark"))
                    } icon: {
                        Image(
                            systemName: selection.map(recorder.isBookmarked) == true
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                }
                .disabled(selection == nil)

                Button {
                    comparisonEntryID = selection
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Set comparison baseline"))
                    } icon: {
                        Image(systemName: "arrow.left.and.right")
                    }
                }
                .disabled(selection == nil)

                Button {
                    stepSelection(by: -1)
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Previous event"))
                    } icon: {
                        Image(systemName: "chevron.up")
                    }
                }
                .disabled(!canStepSelection(by: -1))

                Button {
                    stepSelection(by: 1)
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Next event"))
                    } icon: {
                        Image(systemName: "chevron.down")
                    }
                }
                .disabled(!canStepSelection(by: 1))

                Button {
                    selection = nil
                    comparisonEntryID = nil
                    recorder.clear()
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Clear"))
                    } icon: {
                        Image(systemName: "trash")
                    }
                }

#if os(iOS) || os(macOS) || os(visionOS)
                Button {
                    isImporting = true
                } label: {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Import"))
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }

                ShareLink(item: exportText) {
                    Label {
                        Text(verbatim: routerInspectorLocalized("Export"))
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
            Text(verbatim: routerInspectorLocalized("Import failed")),
            isPresented: Binding(
                get: { importFailed },
                set: { importFailed = $0 }
            )
        ) {
            Button(routerInspectorLocalized("OK")) { importFailed = false }
        } message: {
            Text(verbatim: routerInspectorLocalized("Unknown error"))
        }
#endif
    }

    private var exportText: String {
        guard let data = try? recorder.encodedDiagnosticBundle() else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func toggleVisibility(of domain: RouterInspectorDomain) {
        if visibleDomains.contains(domain) {
            visibleDomains.remove(domain)
        } else {
            visibleDomains.insert(domain)
        }
    }

    private var selectedComparison: RouterInspectorStateDiff? {
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
                selection = recorder.entries.first?.id
                comparisonEntryID = nil
            } catch {
                importFailed = true
            }
        }
    }
#endif

    private func canStepSelection(by offset: Int) -> Bool {
        guard !filteredEntries.isEmpty else { return false }
        guard let selection,
              let index = filteredEntries.firstIndex(where: { $0.id == selection }) else {
            return true
        }
        return filteredEntries.indices.contains(index + offset)
    }

    private func stepSelection(by offset: Int) {
        guard !filteredEntries.isEmpty else { return }
        guard let selection,
              let index = filteredEntries.firstIndex(where: { $0.id == selection }) else {
            self.selection = offset < 0 ? filteredEntries.last?.id : filteredEntries.first?.id
            return
        }
        let target = index + offset
        guard filteredEntries.indices.contains(target) else { return }
        self.selection = filteredEntries[target].id
    }
}

private struct RouterInspectorRow: View {
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
                    Text(verbatim: routerInspectorLocalized("Bookmarked"))
                } icon: {
                    Image(systemName: "bookmark.fill")
                }
                .font(.caption)
            }
            Text(verbatim: entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct RouterInspectorDetail: View {
    let entry: RouterInspectorEntry
    let comparison: RouterInspectorStateDiff?

    var body: some View {
        Form {
            LabeledContent {
                Text(verbatim: entry.domain.rawValue)
            } label: {
                Text(verbatim: routerInspectorLocalized("Domain"))
            }
            LabeledContent {
                Text(verbatim: entry.name)
            } label: {
                Text(verbatim: routerInspectorLocalized("Event"))
            }
            LabeledContent {
                Text(verbatim: entry.outcome.rawValue)
            } label: {
                Text(verbatim: routerInspectorLocalized("Outcome"))
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
                        Text(verbatim: routerInspectorLocalized("Pure reducer"))
                    }
                    if let error = replay.error {
                        LabeledContent {
                            Text(verbatim: error)
                        } label: {
                            Text(verbatim: routerInspectorLocalized("Error"))
                        }
                    }
                } header: {
                    Text(verbatim: routerInspectorLocalized("Replay preview"))
                }
            }
            if let diff = entry.diff {
                Section {
                    if diff.changes.isEmpty {
                        Text(verbatim: routerInspectorLocalized("No structural changes"))
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
                    Text(verbatim: routerInspectorLocalized("State diff"))
                }
            }
            if entry.diff == nil, let comparison {
                Section {
                    if comparison.changes.isEmpty {
                        Text(verbatim: routerInspectorLocalized("No structural changes"))
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
                    Text(verbatim: routerInspectorLocalized("Previous captured state"))
                }
            }
            if let state = entry.state {
                Section {
                    ForEach(state.flattenedNodes) { row in
                        RouterInspectorStateRow(row: row)
                    }
                } header: {
                    Text(verbatim: routerInspectorLocalized("State tree"))
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
