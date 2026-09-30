import Foundation
import Observation

/// View-local projection. Filtering never changes the recorder or revives a
/// selection that disappeared from the visible timeline.
@MainActor
@Observable
final class RouterInspectorTimeline {
    var selection: RouterInspectorEntry.ID?
    var searchText = "" { didSet { refilter() } }
    var visibleDomains = Set(RouterInspectorDomain.allCases) { didSet { refilter() } }
    private(set) var filteredEntries: [RouterInspectorEntry] = []
    @ObservationIgnored private var entries: [RouterInspectorEntry] = []

    var selectedEntry: RouterInspectorEntry? {
        filteredEntries.first { $0.id == selection }
    }

    func updateEntries(_ entries: [RouterInspectorEntry]) {
        self.entries = entries
        refilter()
    }

    func toggleVisibility(of domain: RouterInspectorDomain) {
        if visibleDomains.contains(domain) {
            visibleDomains.remove(domain)
        } else {
            visibleDomains.insert(domain)
        }
    }

    func canStepSelection(by offset: Int) -> Bool {
        targetSelection(by: offset) != nil
    }

    func stepSelection(by offset: Int) {
        guard let target = targetSelection(by: offset) else { return }
        selection = target
    }

    private func targetSelection(by offset: Int) -> RouterInspectorEntry.ID? {
        guard let index = filteredEntries.firstIndex(where: { $0.id == selection }) else {
            return offset < 0 ? filteredEntries.last?.id : filteredEntries.first?.id
        }
        let (target, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, filteredEntries.indices.contains(target) else { return nil }
        return filteredEntries[target].id
    }

    private func refilter() {
        let needle = searchText.localizedLowercase
        filteredEntries = entries.filter { entry in
            guard visibleDomains.contains(entry.domain) else { return false }
            return needle.isEmpty
                || entry.name.localizedLowercase.contains(needle)
                || entry.domain.rawValue.localizedLowercase.contains(needle)
                || entry.outcome.rawValue.localizedLowercase.contains(needle)
                || entry.metadata.contains { key, value in
                    key.localizedLowercase.contains(needle)
                        || value.localizedLowercase.contains(needle)
                }
        }
        if selectedEntry == nil { selection = nil }
    }
}
