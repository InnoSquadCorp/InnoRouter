import Testing
@testable import InnoRouterInspector

@MainActor
@Suite("Inspector execution diagnostics")
struct RouterInspectorExecutionTraceTests {
    #if !DEBUG
    @Test("Release diagnostics stay disabled even if the process opts in")
    func releaseGate() {
        #expect(RouterInspectorExecutionTrace.shared.begin() == nil)
    }
    #endif

    @Test("Disabled diagnostics emit nothing and allocate no execution identifier")
    func disabled() {
        var lines: [String] = []
        let trace = RouterInspectorExecutionTrace(enabled: false) { lines.append($0) }
        #expect(trace.begin() == nil)
        trace.record("task.enter")
        #expect(lines.isEmpty)
    }

    @Test("An exhausted trace emits one limit marker and stops")
    func bounded() {
        var lines: [String] = []
        let trace = RouterInspectorExecutionTrace(enabled: true, capacity: 3) { lines.append($0) }
        let run = trace.begin()
        trace.record("task.enter", run: run)
        for _ in 0..<1_000 { trace.record("store.submit", run: run) }
        #expect(trace.begin() == nil)
        #expect(lines.count == 3)
        #expect(lines.last == "seq=3 event=trace.limit")
    }

    @Test("Overlapping task lifetimes retain distinct execution identifiers")
    func correlation() {
        var lines: [String] = []
        let trace = RouterInspectorExecutionTrace(enabled: true) { lines.append($0) }
        let first = trace.begin()
        let second = trace.begin()
        trace.record("task.exit", run: first, status: .cancelled)
        trace.record("task.enter", run: second)
        #expect(first == 1)
        #expect(second == 2)
        #expect(lines[2] == "seq=3 run=1 event=task.exit status=cancelled")
        #expect(lines[3] == "seq=4 run=2 event=task.enter status=-")
    }
}
