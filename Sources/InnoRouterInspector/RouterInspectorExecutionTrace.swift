import Foundation

/// Internal, opt-in probe diagnostics. Never records URLs, routes, or policy messages.
@MainActor
final class RouterInspectorExecutionTrace {
    static let shared = RouterInspectorExecutionTrace(enabled: {
        #if DEBUG
        ProcessInfo.processInfo.environment["INNOROUTER_INSPECTOR_TRACE"] == "1"
        #else
        false
        #endif
    }()) { line in
        let prefix = "INSPECTOR_EXECUTION pid=\(ProcessInfo.processInfo.processIdentifier) "
        FileHandle.standardError.write(Data((prefix + line + "\n").utf8))
    }

    private let enabled: Bool
    private let capacity: Int
    private let emit: (String) -> Void
    private var emitted = 0
    private var nextRun = 0

    init(enabled: Bool, capacity: Int = 256, emit: @escaping (String) -> Void) {
        self.enabled = enabled
        self.capacity = max(1, capacity)
        self.emit = emit
    }

    func begin() -> Int? {
        guard enabled, emitted < capacity else { return nil }
        nextRun += 1
        record("execute.action", run: nextRun)
        return nextRun
    }

    func record(_ event: StaticString, run: Int? = nil, status: RouterInspectorExecutionStatus? = nil) {
        guard enabled, emitted < capacity else { return }
        emitted += 1
        // Reserve the last line so missing later events cannot look like non-entry.
        guard emitted < capacity else {
            emit("seq=\(emitted) event=trace.limit")
            return
        }
        emit("seq=\(emitted) run=\(run ?? 0) event=\(event) status=\(status?.rawValue ?? "-")")
    }
}
