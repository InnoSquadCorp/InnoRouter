import Foundation

// Opt-in Debug diagnostics for native-scene ordering. No route payloads.
// Buffer in callbacks; the diagnostic probe flushes only after its verdict.
@MainActor
enum RouterSceneLifecycleTrace {
#if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["INNOROUTER_SCENE_TRACE"] == "1"
    private static var lines: [String] = []
    private static var flushedCount = 0
#endif

    static func record(_ event: String, _ fields: @autoclosure () -> String = "") {
#if DEBUG
        guard enabled, lines.count < 256 else { return }
        let sequence = lines.count + 1
        let recordedEvent = sequence == 256 ? "trace.limit" : event
        lines.append("SCENE_TRACE seq=\(sequence) time=\(Date().timeIntervalSince1970) event=\(recordedEvent) \(fields())")
#endif
    }

    static func flush() {
#if DEBUG
        guard lines.count > flushedCount else { return }
        FileHandle.standardOutput.write(Data((lines[flushedCount...].joined(separator: "\n") + "\n").utf8))
        flushedCount = lines.count
#endif
    }
}
