import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterInspector

@Suite("Inspector production non-UI contracts")
@MainActor
struct RouterInspectorPortableContractTests {
    private enum R: Route {
        case secret(String)
    }

    private let outerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let innerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let payload = "PRIVATE-route-query-token@example.test"
    private var grandchildPath: RouterScopePath {
        .root.appendingPresentation(outerID).appendingPresentation(innerID)
    }

    private func nested() throws -> RouterState<R> {
        try RouterState(root: .stack(path: [.secret(payload)], presentation: .init(
            id: outerID, route: .secret(payload), style: .sheet,
            node: .stack(path: [.secret(payload)], presentation: .init(
                id: innerID, route: .secret(payload), style: .popover,
                node: .stack(path: [.secret(payload)])
            ))
        )))
    }

    @Test("Nested modal projection retains all descendants with unique redacted identities")
    func nestedProjection() throws {
        let tree = RouterInspectorProjection.tree(from: try nested())
        #expect(tree.flattenedNodes.map(\.id) == ["/", "/presentation", "/presentation/presentation"])
        #expect(tree.flattenedNodes.map(\.depth) == [0, 1, 2])
        #expect(Set(tree.flattenedNodes.map(\.id)).count == 3)
        #expect(tree.flattenedNodes.map { $0.node.details["routes"] } == ["1", "1", "1"])
        #expect(tree.flattenedNodes.map { $0.node.details["presentation"] } == ["sheet", "popover", "none"])
        let json = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)
        for secret in [payload, outerID.uuidString, innerID.uuidString] {
            #expect(!json.contains(secret))
        }
    }

    @Test("Nested modal child diffs affect only the actual child stack")
    func nestedDiffAndReducerReplay() throws {
        let before = try nested()
        let action = RouterAction<R>.push(.secret(payload)).inScope(grandchildPath)
        let after = try RouterReducer.reduce(action, from: before)
        let diff = RouterInspectorProjection.diff(from: before, to: after)
        #expect(diff.changes == [.init(path: "/presentation/presentation", field: "routes", before: "1", after: "2")])
        let transition = RouterTransition(id: .init(), action: action, initialState: before,
                                          proposedState: after, initialRevision: 4)
        let replay = RouterInspectorReplay.preview(transition)
        #expect(replay.status == .matchedProposal)
        #expect(replay.state == RouterInspectorProjection.tree(from: after))
        #expect(replay.error == nil)
        #expect(before.node(at: grandchildPath) == .stack(path: [.secret(payload)]))
        var mismatch = transition
        mismatch.proposedState = before
        #expect(RouterInspectorReplay.preview(mismatch).status == .proposalMismatch)
    }

    @Test("Replay rejects invalid child actions without exposing route or identity payloads")
    func rejectedReplay() throws {
        let before = try nested()
        let action = RouterAction<R>.push(.secret(payload)).inScope(.root.appendingPresentation(UUID()))
        let transition = RouterTransition(id: .init(), action: action, initialState: before,
                                          proposedState: before, initialRevision: 4)
        let replay = RouterInspectorReplay.preview(transition)
        #expect(replay.status == .rejected)
        #expect(replay.state == nil)
        #expect(replay.error == "RouterMutationError")
        #expect(!String(decoding: try JSONEncoder().encode(replay), as: UTF8.self).contains(payload))
    }

    @Test("Container branches and scenes preserve unique structural modal paths")
    func sceneAndBranchProjection() throws {
        let container = try RouterContainerState<R>(style: .tabs, selection: "PRIVATE-branch", branches: [
            .init(id: "PRIVATE-branch", node: nested().root),
            .init(id: "PRIVATE-sibling", node: .stack()),
        ])
        let state = try RouterState<R>(
            root: .container(container),
            windows: [.init(route: .secret(payload), node: .stack(presentation: .init(route: .secret(payload), style: .sheet)))],
            immersiveSpace: .init(id: "PRIVATE-scene", route: .secret(payload))
        )
        let tree = RouterInspectorProjection.tree(from: state)
        let ids = tree.flattenedNodes.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("/branch[0]/presentation/presentation"))
        #expect(ids.contains("/window[0]/presentation"))
        #expect(tree.root.details["selection"] == "branch[0]")
        let json = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)
        #expect(!json.contains("PRIVATE"))
    }

    @Test("The default router formatter redacts child routes and policy rejection messages")
    func defaultRedaction() throws {
        let state = try nested()
        let formatter: RouterInspectorFormatter<RouterEvent<R>> = redactedRouterFormatter()
        let id = RouterTransitionID()
        let transition = RouterTransition(id: id, action: .push(.secret(payload)).inScope(grandchildPath),
                                          initialState: state, proposedState: state, initialRevision: 3)
        let started = formatter(.started(transition))
        #expect(started.metadata["action"] == "presentationScoped.presentationScoped.push")
        let committed = formatter(.committed(transitionID: id, before: state, after: state, revision: 4, context: .init()))
        #expect(committed.metadata["after"] == "stacks=3,routes=3,presentations=2,windows=0,immersive=0")
        let policy = formatter(.policyPrepared(transitionID: id, policy: "auth", decision: .reject(payload)))
        #expect(policy.outcome == .rejected)
        let rejected = formatter(.rejected(transitionID: id, state: state, revision: 3,
                                           reason: .policy(name: "auth", message: payload), context: .init()))
        #expect(rejected.metadata["reason"] == "policy")
        let recorder = RouterInspectorRecorder()
        for description in [started, committed, policy, rejected] {
            recorder.record(domain: .router, description: description)
        }
        let bytes = try recorder.encodedDiagnosticBundle(platform: .macOS)
        let json = String(decoding: bytes, as: UTF8.self)
        for secret in [payload, outerID.uuidString, innerID.uuidString] { #expect(!json.contains(secret)) }
    }

    @Test("Nested state, diff, replay, bookmarks and environment survive exported bundles")
    func nestedBundleRoundTripAndPlayback() throws {
        let before = try nested()
        let after = try RouterReducer.reduce(.push(.secret(payload)).inScope(grandchildPath), from: before)
        let formatter: RouterInspectorFormatter<RouterEvent<R>> = redactedRouterFormatter()
        let transition = RouterTransition(id: .init(), action: .push(.secret(payload)).inScope(grandchildPath),
                                          initialState: before, proposedState: after, initialRevision: 0)
        let source = RouterInspectorRecorder()
        source.record(domain: .router, description: formatter(.started(transition)))
        source.record(domain: .router, description: formatter(.committed(transitionID: transition.id,
                                                                 before: before, after: after, revision: 1, context: .init())))
        source.toggleBookmark(source.entries[0].id)
        let generatedAt = Date(timeIntervalSince1970: 300)
        let bytes = try source.encodedDiagnosticBundle(platform: .visionOS, frameworkVersion: "test-version", generatedAt: generatedAt)
        #expect(bytes == (try source.encodedDiagnosticBundle(platform: .visionOS, frameworkVersion: "test-version", generatedAt: generatedAt)))
        let target = RouterInspectorRecorder()
        let bundle = try target.importDiagnosticBundle(from: bytes)
        #expect(bundle.frameworkVersion == "test-version")
        #expect(bundle.platform == .visionOS)
        #expect(target.snapshot(generatedAt: generatedAt) == source.snapshot(generatedAt: generatedAt))
        let playback = RouterInspectorPlayback(snapshot: bundle.snapshot)
        #expect(playback.currentEntry?.replay?.status == .matchedProposal)
        #expect(!playback.canStepBackward)
        playback.setComparisonEntry(source.entries[0].id)
        playback.stepForward()
        #expect(!playback.canStepForward)
        #expect(playback.comparisonToPreviousState == source.entries[1].diff)
        #expect(playback.comparisonToSelectedState == source.entries[1].diff)
        #expect(RouterInspectorComparison.finalStates(in: .init(entries: [source.entries[0]]), and: bundle.snapshot) == source.entries[1].diff)
    }

    @Test("Depth limits cover unknown fields before decoding and preserve recorder state")
    func depthPreflightIsAtomic() throws {
        let recorder = sentinel(limits: .init(maximumJSONDepth: 4))
        let original = recorder.snapshot(generatedAt: .distantPast)
        let data = Data(#"{"generatedAt":0,"entries":[],"unknown":[[[[]]]]}"#.utf8)
        let calls = DecodeCalls()
        let decoder = observingDecoder(calls)
        #expect(throws: RouterInspectorImportError.jsonDepthExceeded(actualDepth: 5, maximumDepth: 4)) {
            try recorder.importSnapshot(from: data, decoder: decoder)
        }
        #expect(calls.count.withLock { $0 } == 0)
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
        #expect(throws: RouterInspectorImportError.jsonDepthExceeded(actualDepth: 5, maximumDepth: 4)) {
            try RouterInspectorImportPreflight.isDiagnosticBundle(data, limits: recorder.importLimits)
        }
    }

    @Test("Adversarial unknown-field nesting is rejected iteratively at the default depth")
    func deeplyNestedUnknownField() throws {
        let recorder = sentinel(limits: .default)
        let original = recorder.snapshot(generatedAt: .distantPast)
        let json = "{\"generatedAt\":0,\"entries\":[],\"unknown\":"
            + String(repeating: "[", count: 50_000) + "0"
            + String(repeating: "]", count: 50_000) + "}"
        #expect(throws: RouterInspectorImportError.jsonDepthExceeded(actualDepth: 65, maximumDepth: 64)) {
            try recorder.importSnapshot(from: Data(json.utf8))
        }
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
    }

    @Test("Token limits cover unknown fields before decoding and preserve recorder state")
    func tokenPreflightIsAtomic() throws {
        let recorder = sentinel(limits: .init(maximumJSONTokens: 13))
        let original = recorder.snapshot(generatedAt: .distantPast)
        let calls = DecodeCalls()
        let data = Data(#"{"generatedAt":0,"entries":[],"unknown":[0]}"#.utf8)
        #expect(throws: RouterInspectorImportError.jsonTokenLimitExceeded(actualCount: 14, maximumCount: 13)) {
            try recorder.importSnapshot(from: data, decoder: observingDecoder(calls))
        }
        #expect(calls.count.withLock { $0 } == 0)
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
    }

    @Test("Configured JSON boundaries accept exact limits and reject the next token or depth")
    func exactJSONBoundaries() throws {
        // Fourteen tokens, maximum container depth two (object + entries array).
        let data = Data(#"{"generatedAt":0,"entries":[],"unknown":0}"#.utf8)
        let recorder = RouterInspectorRecorder(importLimits: .init(maximumJSONDepth: 2, maximumJSONTokens: 14))
        try recorder.importSnapshot(from: data)
        #expect(recorder.entries.isEmpty)
        #expect(throws: RouterInspectorImportError.jsonTokenLimitExceeded(actualCount: 14, maximumCount: 13)) {
            try RouterInspectorImportPreflight.validate(data, limits: .init(maximumJSONTokens: 13))
        }
        #expect(throws: RouterInspectorImportError.jsonDepthExceeded(actualDepth: 2, maximumDepth: 1)) {
            try RouterInspectorImportPreflight.validate(data, limits: .init(maximumJSONDepth: 1))
        }
    }

    @Test("Entry and byte limits run before a caller-provided decoder")
    func entryAndBytePreflight() throws {
        let calls = DecodeCalls()
        let recorder = sentinel(limits: .init(maximumEncodedByteCount: 128, maximumEntryCount: 1))
        let original = recorder.snapshot(generatedAt: .distantPast)
        #expect(throws: RouterInspectorImportError.tooManyEntries(actualCount: 2, maximumCount: 1)) {
            try recorder.importSnapshot(from: Data(#"{"generatedAt":0,"entries":[{},{}]}"#.utf8), decoder: observingDecoder(calls))
        }
        #expect(throws: RouterInspectorImportError.encodedDataTooLarge(actualByteCount: 129, maximumByteCount: 128)) {
            try recorder.importSnapshot(from: Data(repeating: 32, count: 129), decoder: observingDecoder(calls))
        }
        #expect(calls.count.withLock { $0 } == 0)
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
    }

    @Test("Malformed and duplicate nested JSON fail closed before Foundation decoding", arguments: [
        #"{"generatedAt":0,"entries":[],"x":{"a":0,"\u0061":1}}"#,
        #"{"generatedAt":0,"entries":[],"x":[1,]}"#,
        #"{"generatedAt":0,"entries":[]}{}"#,
        #"{"generatedAt":0,"entries":[],"x":"\q"}"#,
        #"{"generatedAt":0,"entries":[],"x":[{]}}"#,
        #"{"generatedAt":0,"entries":[],"x":01}"#,
    ])
    func malformedJSON(json: String) throws {
        let recorder = sentinel(limits: .default)
        let original = recorder.snapshot(generatedAt: .distantPast)
        let calls = DecodeCalls()
        #expect(throws: RouterInspectorImportError.malformedSnapshotEnvelope) {
            try recorder.importSnapshot(from: Data(json.utf8), decoder: observingDecoder(calls))
        }
        #expect(calls.count.withLock { $0 } == 0)
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
    }

    @Test("Unknown entry enum codes reject atomically", arguments: ["domain", "outcome", "kind", "status"])
    func unknownCodes(field: String) throws {
        let tree = RouterInspectorProjection.tree(from: try nested())
        let entry = RouterInspectorEntry(domain: .router, name: "known", outcome: .accepted,
                                          state: tree, replay: .init(status: .matchedProposal, state: tree))
        let bytes = try JSONEncoder().encode(RouterInspectorSnapshot(entries: [entry]))
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        if field == "kind" {
            var state = try #require(entries[0]["state"] as? [String: Any])
            var root = try #require(state["root"] as? [String: Any])
            root[field] = "future-code"
            state["root"] = root
            entries[0]["state"] = state
        } else if field == "status" {
            var replay = try #require(entries[0]["replay"] as? [String: Any])
            replay[field] = "future-code"
            entries[0]["replay"] = replay
        } else { entries[0][field] = "future-code" }
        json["entries"] = entries
        let recorder = sentinel(limits: .default)
        let original = recorder.snapshot(generatedAt: .distantPast)
        #expect(throws: DecodingError.self) {
            try recorder.importSnapshot(from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
    }

    @Test("Sustained records retain only capacity and remove expired timing and bookmarks")
    func sustainedRetention() throws {
        let recorder = RouterInspectorRecorder(capacity: 32)
        for index in 0..<10_000 {
            recorder.record(domain: .router,
                            description: .init(name: "transition.started", metadata: ["transitionID": "event-\(index)"]),
                            timestamp: Date(timeIntervalSince1970: Double(index)))
            if index.isMultiple(of: 100) { recorder.toggleBookmark(recorder.entries.last!.id) }
            #expect(recorder.entries.count <= 32)
            #expect(recorder.bookmarkedEntryIDs.isSubset(of: Set(recorder.entries.map(\.id))))
        }
        recorder.record(domain: .router, description: .init(name: "transition.committed", metadata: ["transitionID": "event-0"]),
                        timestamp: Date(timeIntervalSince1970: 20_000))
        #expect(recorder.entries.last?.metadata["durationMilliseconds"] == nil)
        #expect(recorder.entries.last?.metadata["elapsedSincePreviousMilliseconds"] == nil)
        #expect(recorder.entries.count == 32)
        #expect(try JSONDecoder().decode(RouterInspectorSnapshot.self, from: recorder.encodedSnapshot()).entries.count == 32)
        recorder.clear()
        #expect(recorder.entries.isEmpty)
        #expect(recorder.bookmarkedEntryIDs.isEmpty)
    }

    @Test("Append and replace retain suffixes, deduplicate atomically, and intersect bookmarks")
    func boundedImportRetention() throws {
        let entries = (0..<5).map { RouterInspectorEntry(domain: .router, name: "event-\($0)", outcome: .informational) }
        let recorder = RouterInspectorRecorder(capacity: 3)
        try recorder.importSnapshot(.init(entries: Array(entries.prefix(3)), bookmarkedEntryIDs: Set(entries.prefix(3).map(\.id))))
        try recorder.importSnapshot(.init(entries: Array(entries.suffix(2)), bookmarkedEntryIDs: [entries[4].id]), policy: .append)
        #expect(recorder.entries == Array(entries.suffix(3)))
        #expect(recorder.bookmarkedEntryIDs == [entries[2].id, entries[4].id])
        let original = recorder.snapshot(generatedAt: .distantPast)
        #expect(throws: RouterInspectorImportError.duplicateEntryID(entries[4].id)) {
            try recorder.importSnapshot(.init(entries: [entries[0], entries[4]]), policy: .append)
        }
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
        try recorder.importSnapshot(.init(entries: entries, bookmarkedEntryIDs: [entries[0].id, entries[3].id]))
        #expect(recorder.entries == Array(entries.suffix(3)))
        #expect(recorder.bookmarkedEntryIDs == [entries[3].id])
    }

    @Test("Pause on rejection, manual pause and resume preserve recorder ordering")
    func pauseAndResume() {
        let recorder = RouterInspectorRecorder()
        recorder.setPauseOnRejection(true)
        recorder.record(domain: .router, description: .init(name: "denied", outcome: .rejected))
        #expect(recorder.isPaused)
        recorder.record(domain: .router, description: .init(name: "ignored"))
        #expect(recorder.entries.map(\.name) == ["denied"])
        recorder.resume()
        recorder.record(domain: .router, description: .init(name: "resumed"))
        recorder.pause()
        recorder.record(domain: .router, description: .init(name: "ignored-again"))
        #expect(recorder.entries.map(\.name) == ["denied", "resumed"])
    }

    private func sentinel(limits: RouterInspectorImportLimits) -> RouterInspectorRecorder {
        let recorder = RouterInspectorRecorder(importLimits: limits)
        recorder.record(domain: .application, description: .init(name: "sentinel"))
        recorder.toggleBookmark(recorder.entries[0].id)
        return recorder
    }

    private final class DecodeCalls: Sendable {
        let count = Mutex(0)
    }

    private func observingDecoder(_ calls: DecodeCalls) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { _ in
            calls.count.withLock { $0 += 1 }
            throw CocoaError(.coderReadCorrupt)
        }
        return decoder
    }
}
