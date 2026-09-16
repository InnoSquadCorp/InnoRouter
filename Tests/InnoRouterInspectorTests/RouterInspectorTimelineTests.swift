import Testing
@testable import InnoRouterInspector

@MainActor
struct RouterInspectorTimelineTests {
    private let committed = RouterInspectorEntry(
        domain: .router, name: "transition.committed", outcome: .accepted,
        metadata: ["source": "deepLink"]
    )
    private let rejected = RouterInspectorEntry(
        domain: .application, name: "request.denied", outcome: .rejected
    )

    @Test func searchClearsHiddenSelectionWithoutResurrectingIt() {
        let timeline = RouterInspectorTimeline()
        timeline.updateEntries([committed, rejected])
        timeline.selection = committed.id
        timeline.searchText = "no-such-event-600"
        #expect(timeline.filteredEntries.isEmpty)
        #expect(timeline.selection == nil)
        #expect(timeline.selectedEntry == nil)
        #expect(!timeline.canStepSelection(by: 1))
        timeline.searchText = ""
        #expect(timeline.filteredEntries.count == 2)
        #expect(timeline.selection == nil)
    }

    @Test func matchingSearchKeepsSelectionAndSearchesMetadata() {
        let timeline = RouterInspectorTimeline()
        timeline.updateEntries([committed, rejected])
        timeline.selection = committed.id
        for query in ["COMMITTED", "ROUTER", "ACCEPTED", "SOURCE", "DEEPLINK"] {
            timeline.searchText = query
            #expect(timeline.filteredEntries == [committed])
            #expect(timeline.selectedEntry == committed)
        }
    }

    @Test func domainFilterClearsSelectionAndComposesWithSearch() {
        let timeline = RouterInspectorTimeline()
        timeline.updateEntries([committed, rejected])
        timeline.selection = committed.id
        timeline.toggleVisibility(of: .router)
        #expect(timeline.filteredEntries == [rejected])
        #expect(timeline.selection == nil)
        timeline.searchText = "committed"
        #expect(timeline.filteredEntries.isEmpty)
        timeline.toggleVisibility(of: .router)
        #expect(timeline.filteredEntries == [committed])
        #expect(timeline.selection == nil)
    }

    @Test func evictionAndClearInvalidateDetail() {
        let timeline = RouterInspectorTimeline()
        timeline.updateEntries([committed, rejected])
        timeline.selection = committed.id
        timeline.updateEntries([rejected])
        #expect(timeline.selectedEntry == nil)
        #expect(timeline.selection == nil)
        timeline.selection = rejected.id
        timeline.updateEntries([])
        #expect(timeline.selectedEntry == nil)
        #expect(timeline.selection == nil)
    }

    @Test func steppingUsesOnlyVisibleRowsAndRespectsBoundaries() {
        let timeline = RouterInspectorTimeline()
        timeline.updateEntries([committed, rejected])
        timeline.stepSelection(by: -1)
        #expect(timeline.selectedEntry == rejected)
        #expect(!timeline.canStepSelection(by: 1))
        #expect(!timeline.canStepSelection(by: Int.max))
        timeline.stepSelection(by: -1)
        #expect(timeline.selectedEntry == committed)
        #expect(!timeline.canStepSelection(by: -1))
        timeline.searchText = "denied"
        #expect(timeline.selection == nil)
        timeline.stepSelection(by: 1)
        #expect(timeline.selectedEntry == rejected)
        #expect(!timeline.canStepSelection(by: -1))
    }

    @Test func newEventsAreFilteredWithoutDiscardingVisibleSelection() {
        let timeline = RouterInspectorTimeline()
        timeline.searchText = "committed"
        timeline.updateEntries([committed])
        timeline.selection = committed.id
        timeline.updateEntries([committed, rejected])
        #expect(timeline.filteredEntries == [committed])
        #expect(timeline.selectedEntry == committed)
    }
}
