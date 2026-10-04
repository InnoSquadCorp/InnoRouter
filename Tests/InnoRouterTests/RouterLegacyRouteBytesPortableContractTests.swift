import Foundation
import Synchronization
import Testing

import InnoRouterCore

@Suite("Exact legacy route JSON spans", .serialized)
struct RouterLegacyRouteBytesPortableContractTests {
    private struct Blob: Route, Codable {
        let text: String
        static let calls = Mutex(0)
        init(text: String) { self.text = text }
        private enum CodingKeys: String, CodingKey { case text }
        init(from decoder: any Decoder) throws {
            Self.calls.withLock { $0 += 1 }
            text = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .text)
        }
    }

    private func envelope(_ payload: Data) throws -> Data {
        try JSONEncoder().encode(RouterSnapshotEnvelope(schemaVersion: 17, payload: payload))
    }

    @Test("Per-route exact bound and limit plus one precede app decoding", arguments: [false, true])
    func exactRouteBytes(excess: Bool) throws {
        let original = Blob(text: "boundary")
        let maximum = try JSONEncoder().encode(original).count
        let route = Blob(text: original.text + (excess ? "x" : ""))
        let raw = try JSONEncoder().encode(RouterState<Blob>.rootStack(path: [route]))
        let data = try envelope(raw)
        let codec = try RouterSnapshotCodec<Blob>(currentVersion: 17, resourceBudget: .init(snapshot: .init(maximumRoutePayloadBytes: maximum)))
        Blob.calls.withLock { $0 = 0 }
        if excess {
            do { _ = try codec.decode(data); Issue.record("Expected route-byte rejection") }
            catch RouterSnapshotError.preflight(let failure) {
                #expect(failure.details.field == "routePayloadBytes")
                #expect(failure.details.actual == maximum + 1)
                #expect(failure.details.maximum == maximum)
            }
            #expect(Blob.calls.withLock { $0 } == 0)
        } else {
            #expect(try codec.decode(data) == .rootStack(path: [route]))
            #expect(Blob.calls.withLock { $0 } == 1)
        }
    }

    @Test("Original escaped bytes are counted instead of a normalized re-encoding")
    func escapedWireBytes() throws {
        let route = Blob(text: "home")
        let maximum = try JSONEncoder().encode(route).count
        let raw = try JSONEncoder().encode(RouterState<Blob>.rootStack(path: [route]))
        let escaped = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"home\"", with: "\"\\u0068ome\"").utf8)
        let codec = try RouterSnapshotCodec<Blob>(currentVersion: 17, resourceBudget: .init(snapshot: .init(maximumRoutePayloadBytes: maximum)))
        Blob.calls.withLock { $0 = 0 }
        do { _ = try codec.decode(envelope(escaped)); Issue.record("Expected original wire-byte rejection") }
        catch RouterSnapshotError.preflight(let failure) {
            #expect(failure.details.field == "routePayloadBytes")
            #expect(failure.details.actual == maximum + 5)
        }
        #expect(Blob.calls.withLock { $0 } == 0)
    }

    @Test("Outgoing legacy snapshots also reject per-route excess before returning storage bytes")
    func encodeDoesNotReturnOversizedRoute() throws {
        let codec = try RouterSnapshotCodec<Blob>(currentVersion: 17, resourceBudget: .init(snapshot: .init(maximumRoutePayloadBytes: 16)))
        #expect(throws: RouterSnapshotError.self) {
            try codec.encode(.rootStack(path: [.init(text: String(repeating: "x", count: 64))]))
        }
    }
}
