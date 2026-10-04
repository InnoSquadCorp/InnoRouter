import Foundation
import Testing
import InnoRouterCore
@testable import InnoRouterSystem

@Suite("Future diagnostic code")
@MainActor
struct RouterDiagnosticFutureCodeTests {
    @Test("Unknown wire codes round trip without ending a known transition")
    func unknownKindRetainsInterval() throws {
        let kind = try JSONDecoder().decode(RouterDiagnosticEventKind.self, from: Data("\"future.kind\"".utf8))
        #expect(kind.rawValue == "future.kind")
        #expect(String(decoding: try JSONEncoder().encode(kind), as: UTF8.self) == "\"future.kind\"")
        #expect(try JSONDecoder().decode(RouterDiagnosticEventKind.self, from: Data("\"committed\"".utf8)) == .committed)
        var begins = 0
        var ends = 0
        var lifecycle = 0
        let tracker = RouterSignpostTracker<Int>(
            begin: { begins += 1; return begins },
            end: { _ in ends += 1 },
            point: { point, _ in if case .lifecycle = point { lifecycle += 1 } }
        )
        let id = RouterTransitionID()
        tracker.record(.init(kind: .started, transitionID: id))
        tracker.record(.init(kind: kind, transitionID: id))
        #expect(begins == 1 && ends == 0 && lifecycle == 1)
        tracker.record(.init(kind: .committed, transitionID: id))
        #expect(ends == 1)
    }
}
