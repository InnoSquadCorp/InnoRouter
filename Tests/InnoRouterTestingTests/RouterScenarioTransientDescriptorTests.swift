import Foundation
import Synchronization
import Testing

import InnoRouter
import InnoRouterTesting

private enum DescriptorRoute: String, Route, Codable {
    case home
    static let calls = Mutex((encode: 0, decode: 0))

    init(from decoder: any Decoder) throws {
        Self.calls.withLock { $0.decode += 1 }
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown route"))
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        Self.calls.withLock { $0.encode += 1 }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

@Suite("Bounded transient scenario descriptors", .serialized)
struct RouterScenarioTransientDescriptorTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!

    private func descriptor(title: String = "Confirm") -> RouterTransientPresentation {
        .init(id: id, content: .init(title: title, message: "Inert fixture text", actions: [
            .init(id: "continue", label: "Continue"),
            .init(id: "cancel", label: "Cancel", role: .cancel),
        ]))
    }

    private func fixture(dialog: Bool = false, title: String = "Confirm") throws -> RouterScenarioFixture<DescriptorRoute> {
        let family: RouterPresentationFamily<DescriptorRoute> = dialog
            ? .confirmationDialog(descriptor(title: title)) : .alert(descriptor(title: title))
        let initial = try RouterState(root: RouterNode<DescriptorRoute>.stack(path: [.home], presentationFamily: family))
        let final = RouterState<DescriptorRoute>.rootStack(path: [.home])
        return .init(initialState: initial, steps: [
            .init(action: .selectPresentationAction(presentationID: id, actionID: "continue"), context: .init(),
                  observedState: final, observedRevision: 1, observedTerminal: .applied,
                  expectation: .init(state: final, revision: 1, terminal: .applied)),
        ])
    }

    private func reset() { DescriptorRoute.calls.withLock { $0 = (0, 0) } }
    private var decodes: Int { DescriptorRoute.calls.withLock { $0.decode } }
    private var encodes: Int { DescriptorRoute.calls.withLock { $0.encode } }

    @Test("Dedicated export round-trips both families and never calls app routes in shape passes", arguments: [false, true])
    func boundedRoundTrip(dialog: Bool) throws {
        let original = try fixture(dialog: dialog)
        let data = try original.encode()
        reset()
        let decoded = try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
        #expect(decoded == original)
        #expect(decoded.formatVersion == 9)
        #expect(decodes == 3) // Initial, observed and expected paths; no shape callbacks.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("presentationFamily"))
        #expect(text.contains(dialog ? "confirmationDialog" : "alert"))
        #expect(!text.contains("callbackToken"))
        #expect(!text.contains("authorizationEpoch"))
        #expect(!text.contains("typedResult"))
    }

    @Test("Bare state, action and fixture coding reject, including guessed capability keys")
    func rawCodingCannotOptIn() throws {
        let original = try fixture()
        let encoder = JSONEncoder()
        encoder.userInfo[CodingUserInfoKey(rawValue: "InnoRouter.testing.transientDescriptors")!] = true
        #expect(throws: RouterTransientPresentationPersistenceFailure.transientPresent) { try encoder.encode(original.initialState) }
        #expect(throws: RouterTransientPresentationPersistenceFailure.transientPresent) {
            try encoder.encode(RouterAction<DescriptorRoute>.presentAlert(descriptor()))
        }
        #expect(throws: RouterTransientPresentationPersistenceFailure.transientPresent) { try encoder.encode(original) }
        let data = try original.encode()
        let decoder = JSONDecoder()
        decoder.userInfo[CodingUserInfoKey(rawValue: "InnoRouter.testing.transientDescriptors")!] = true
        #expect(throws: RouterTransientPresentationPersistenceFailure.unsupportedRestoration) {
            try decoder.decode(RouterScenarioFixture<DescriptorRoute>.self, from: data)
        }
    }

    @Test("Version-eight navigation is retained and upgraded without inventing a family")
    func oldNavigationCompatibility() throws {
        let state = RouterState<DescriptorRoute>.rootStack(path: [.home])
        let nav = RouterScenarioFixture(initialState: state, steps: [
            .init(action: .apply(.init(state: state)), context: .init(), observedState: state,
                  observedRevision: 0, observedTerminal: .unchanged,
                  expectation: .init(state: state, revision: 0, terminal: .unchanged)),
        ])
        let data = try replacing(try nav.encode()) { $0["formatVersion"] = 8 }
        let decoded = try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
        #expect(decoded.initialState == state)
        #expect(decoded.steps == nav.steps)
        #expect(decoded.controls == nav.controls)
        #expect(decoded.formatVersion == 9)
        let object = try object(decoded.encode())
        let initial = try #require(object["initialState"] as? [String: Any])
        let root = try #require(initial["root"] as? [String: Any])
        let stackCase = try #require(root["stack"] as? [String: Any])
        let stack = try #require(stackCase["_0"] as? [String: Any])
        #expect(stack["presentationFamily"] == nil)
        #expect(stack["path"] as? [String] == ["home"])
    }

    @Test("Navigation presentation wire fields and opaque app payload keys remain unchanged")
    func navigationWireAndOpaqueRouteFields() throws {
        struct OpaqueRoute: Route, Codable {
            let presentationFamily: String
            let alert: String
            let confirmationDialog: String
        }
        let route = OpaqueRoute(presentationFamily: "futureApplicationData", alert: "business", confirmationDialog: "model")
        let state = try RouterState(root: RouterNode<OpaqueRoute>.stack(
            path: [route], presentation: .init(route: route, style: .sheet)
        ))
        let fixture = RouterScenarioFixture(initialState: state, steps: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(state)
        let exported = try fixture.encode()
        let encodedState = try #require(try object(exported)["initialState"] as? [String: Any])
        #expect(try JSONSerialization.data(withJSONObject: encodedState, options: [.sortedKeys]) == original)
        let old = try replacing(exported) { $0["formatVersion"] = 8 }
        #expect(try RouterScenarioFixture<OpaqueRoute>.decode(from: old).initialState == state)
    }

    @Test("A transient-capable document cannot masquerade as format eight")
    func oldVersionCannotCarryNewFamily() throws {
        let data = try replacing(try fixture().encode()) { $0["formatVersion"] = 8 }
        reset()
        #expect(throws: RouterTransientPresentationPersistenceFailure.unsupportedRestoration) {
            try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
        }
        #expect(decodes == 0)
    }

    @Test("Unknown versions reject before application codecs", arguments: [0, 7, 10, Int.max])
    func unknownVersion(version: Int) throws {
        let data = try replacing(try fixture().encode()) { $0["formatVersion"] = version }
        reset()
        #expect(throws: RouterScenarioFixtureError.unsupportedFormatVersion(version)) {
            try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
        }
        #expect(decodes == 0)
    }

    @Test("Contradictory and ad-hoc stack families reject before app codecs", arguments: ["presentation", "alert", "confirmationDialog"])
    func contradictoryFields(field: String) throws {
        let data = try editingStack(try fixture().encode()) { $0[field] = NSNull() }
        reset()
        #expect(throws: RouterTransientPresentationPersistenceFailure.unsupportedRestoration) {
            try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
        }
        #expect(decodes == 0)
    }

    @Test("Unknown family tags reject before application codecs")
    func unknownFamilyKind() throws {
        let data = try editingStack(try fixture().encode()) { stack in
            var family = try #require(stack["presentationFamily"] as? [String: Any])
            family["kind"] = "futureAlert"
            stack["presentationFamily"] = family
        }
        reset()
        #expect(throws: DecodingError.self) { try RouterScenarioFixture<DescriptorRoute>.decode(from: data) }
        #expect(decodes == 0)
    }

    @Test("Malformed descriptor actions reject in the opaque pass", arguments: ["duplicate", "emptyID", "emptyActions", "multipleCancel", "unknownRole"])
    func malformedDescriptors(kind: String) throws {
        let data = try editingStack(try fixture().encode()) { stack in
            var family = try #require(stack["presentationFamily"] as? [String: Any])
            var descriptor = try #require(family["descriptor"] as? [String: Any])
            var content = try #require(descriptor["content"] as? [String: Any])
            var actions = try #require(content["actions"] as? [[String: Any]])
            switch kind {
            case "duplicate": actions[1]["id"] = actions[0]["id"]
            case "emptyID":
                if actions[0]["id"] is String { actions[0]["id"] = "" }
                else { actions[0]["id"] = ["rawValue": ""] }
            case "emptyActions": actions = []
            case "multipleCancel": actions[0]["role"] = "cancel"
            default: actions[0]["role"] = "executeBusinessCallback"
            }
            content["actions"] = actions; descriptor["content"] = content
            family["descriptor"] = descriptor; stack["presentationFamily"] = family
        }
        reset()
        if kind == "unknownRole" {
            #expect(throws: DecodingError.self) { try RouterScenarioFixture<DescriptorRoute>.decode(from: data) }
        } else {
            let failure: RouterTransientPresentationValidationFailure
            switch kind {
            case "duplicate": failure = .duplicateActionID
            case "emptyID": failure = .emptyActionID
            case "emptyActions": failure = .emptyActions
            default: failure = .multipleCancelActions
            }
            #expect(throws: RouterStateValidationError.invalidTransientPresentation(failure)) {
                try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
            }
        }
        #expect(decodes == 0)
    }

    @Test("Duplicate presentation identities across domains reject before app codecs")
    func duplicatePresentationID() throws {
        let data = try replacing(try fixture().encode()) { root in
            var initial = try #require(root["initialState"] as? [String: Any])
            initial["windows"] = [["id": UUID().uuidString, "route": "home", "node": initial["root"]!]]
            root["initialState"] = initial
        }
        reset()
        #expect(throws: RouterStateValidationError.duplicatePresentation(id)) {
            try RouterScenarioFixture<DescriptorRoute>.decode(from: data)
        }
        #expect(decodes == 0)
    }

    @Test("Original descriptor metadata is admitted before any export route callback")
    func originalStateBudgetBeforeEncoding() throws {
        let original = try fixture(title: String(repeating: "x", count: 65))
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 64))
        reset()
        #expect(throws: RouterScenarioFixtureError.resourceLimit(.init(resource: "state.metadataBytes", actual: 65, maximum: 64))) {
            try original.encode(resourceBudget: budget)
        }
        #expect(encodes == 0)
    }

    @Test("Exact descriptor metadata byte and action-count budgets admit without truncation")
    func originalMetadataBoundaries() throws {
        let original = try fixture()
        let content = descriptor().content
        let bytes = content.title.utf8.count + (content.message?.utf8.count ?? 0)
            + content.actions.reduce(0) { $0 + $1.id.rawValue.utf8.count + $1.label.utf8.count }
        let data = try original.encode(resourceBudget: .init(snapshot: try .init(
            maximumPayloadBytes: bytes, maximumJSONTokens: content.actions.count
        )))
        #expect(try RouterScenarioFixture<DescriptorRoute>.decode(from: data) == original)
        reset()
        #expect(throws: RouterScenarioFixtureError.resourceLimit(.init(resource: "state.metadataBytes", actual: bytes, maximum: bytes - 1))) {
            try original.encode(resourceBudget: .init(snapshot: try .init(maximumPayloadBytes: bytes - 1)))
        }
        #expect(encodes == 0)
        #expect(throws: RouterScenarioFixtureError.resourceLimit(.init(resource: "state.metadataElements", actual: 2, maximum: 1))) {
            try original.encode(resourceBudget: .init(snapshot: try .init(maximumJSONTokens: 1)))
        }
        #expect(encodes == 0)
    }

    @Test("An oversized late action is rejected before earlier route encoding")
    func originalActionBudgetBeforeEncoding() throws {
        let initial = RouterState<DescriptorRoute>.rootStack(path: [.home])
        let original = RouterScenarioFixture(initialState: initial, steps: [
            .init(action: .presentAlert(descriptor(title: String(repeating: "x", count: 65))), context: .init(),
                  observedState: initial, observedRevision: 0, observedTerminal: .rejected),
        ])
        reset()
        #expect(throws: RouterScenarioFixtureError.resourceLimit(.init(resource: "state.metadataBytes", actual: 65, maximum: 64))) {
            try original.encode(resourceBudget: .init(snapshot: try .init(maximumPayloadBytes: 64)))
        }
        #expect(encodes == 0)
    }

    @Test("Zero export work allowance rejects before app Encodable")
    func zeroExportWork() throws {
        let original = try fixture()
        reset()
        #expect(throws: RouterScenarioFixtureError.resourceLimit(.init(resource: "jsonWorkUnits", actual: 1, maximum: 0))) {
            try original.encode(resourceBudget: .init(maximumJSONWorkUnits: 0))
        }
        #expect(encodes == 0)
    }

    @Test("Byte, step, depth and token boundaries precede app decoding")
    func scenarioLimits() throws {
        let data = try fixture().encode()
        #expect(try RouterScenarioFixture<DescriptorRoute>.decode(from: data, maximumByteCount: data.count).steps.count == 1)
        reset()
        #expect(throws: RouterScenarioFixtureError.encodedDataTooLarge(actual: data.count, maximum: data.count - 1)) {
            try RouterScenarioFixture<DescriptorRoute>.decode(from: data, maximumByteCount: data.count - 1)
        }
        #expect(decodes == 0)
        for limit in [1, 2] {
            reset()
            #expect(throws: RouterScenarioFixtureError.self) {
                try RouterScenarioFixture<DescriptorRoute>.decode(from: data, maximumJSONDepth: limit)
            }
            #expect(decodes == 0)
            #expect(throws: RouterScenarioFixtureError.self) {
                try RouterScenarioFixture<DescriptorRoute>.decode(from: data, maximumJSONTokens: limit)
            }
            #expect(decodes == 0)
        }
        let duplicated = try replacing(data) { root in
            let steps = try #require(root["steps"] as? [Any]); root["steps"] = steps + steps
        }
        #expect(try RouterScenarioFixture<DescriptorRoute>.decode(from: duplicated, maximumStepCount: 2).steps.count == 2)
        reset()
        #expect(throws: RouterScenarioFixtureError.tooManySteps(actual: 2, maximum: 1)) {
            try RouterScenarioFixture<DescriptorRoute>.decode(from: duplicated, maximumStepCount: 1)
        }
        #expect(decodes == 0)
    }

    @Test("Classification, descriptor shape and final passes share exact work/key boundaries")
    func sharedWorkBoundary() throws {
        let data = try fixture().encode()
        for keys in [false, true] {
            var low = 0
            var high = data.count * 20
            while low < high {
                let middle = low + (high - low) / 2
                do {
                    _ = try RouterScenarioFixture<DescriptorRoute>.decode(
                        from: data, maximumJSONWorkUnits: keys ? .max : middle,
                        maximumJSONKeyDecodes: keys ? middle : .max
                    )
                    high = middle
                } catch RouterScenarioFixtureError.resourceLimit { low = middle + 1 }
            }
            #expect(low > 0)
            reset()
            #expect(throws: RouterScenarioFixtureError.self) {
                try RouterScenarioFixture<DescriptorRoute>.decode(
                    from: data, maximumJSONWorkUnits: keys ? .max : low - 1,
                    maximumJSONKeyDecodes: keys ? low - 1 : .max
                )
            }
            #expect(decodes == 0)
            _ = try RouterScenarioFixture<DescriptorRoute>.decode(
                from: data, maximumJSONWorkUnits: keys ? .max : low,
                maximumJSONKeyDecodes: keys ? low : .max
            )
            #expect(decodes == 3)
        }
    }

    @Test("Descriptor fixtures are not snapshots or durable pending records")
    func persistenceDoesNotInheritTransport() throws {
        let fixtureData = try fixture().encode()
        let payload = try #require(try object(fixtureData)["initialState"] as? [String: Any])
        let stateData = try JSONSerialization.data(withJSONObject: payload)
        let envelope = try JSONEncoder().encode(RouterSnapshotEnvelope(schemaVersion: 1, payload: stateData))
        reset()
        for limits in [RouterSnapshotLimits?.some(.provisional), nil] {
            let codec = try RouterSnapshotCodec<DescriptorRoute>(currentVersion: 1, limits: limits, transientPresentations: .omit)
            #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try codec.decode(envelope) }
            #expect(decodes == 0)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let record = RouterDurablePendingLink<DescriptorRoute>(link: .init(
            url: URL(string: "https://example.test/fixture")!, gatedRoute: .home,
            plan: .init(state: .rootStack(path: [.home])), matchedRoute: .home
        ), originatedAt: now, lastObservedAt: now)
        let pending = RouterPendingLinkCodec<DescriptorRoute>(transientPresentations: .omit)
        let pendingData = try replacing(pending.encode(record)) { root in
            var link = try #require(root["link"] as? [String: Any])
            var plan = try #require(link["plan"] as? [String: Any])
            plan["state"] = payload; link["plan"] = plan; root["link"] = link
        }
        reset()
        #expect(throws: RouterPendingLinkPersistenceError.transientPresentation(.unsupportedRestoration)) {
            try pending.decode(pendingData, now: now)
        }
        #expect(decodes == 0)
    }

    @Test("Authored descriptor actions replay structurally on an isolated Store", arguments: [false, true])
    @MainActor
    func descriptorReplay(dialog: Bool) async throws {
        let value = descriptor()
        let initial = RouterState<DescriptorRoute>.rootStack(path: [.home])
        let presented = try RouterState(root: RouterNode<DescriptorRoute>.stack(path: [.home], presentationFamily: dialog ? .confirmationDialog(value) : .alert(value)))
        let actions: [RouterAction<DescriptorRoute>] = [
            dialog ? .presentConfirmationDialog(value) : .presentAlert(value),
            .selectPresentationAction(presentationID: id, actionID: "continue"),
            dialog ? .presentConfirmationDialog(value) : .presentAlert(value),
            .dismissPresentation,
        ]
        let states = [presented, initial, presented, initial]
        let original = RouterScenarioFixture(initialState: initial, steps: actions.enumerated().map { index, action in
            .init(submissionIndex: index, submissionEventIndex: index * 2, terminalEventIndex: index * 2 + 1,
                  action: action, context: .init(), observedState: states[index], observedRevision: UInt64(index + 1),
                  observedTerminal: .applied,
                  expectation: .init(state: states[index], revision: UInt64(index + 1), terminal: .applied))
        })
        let decoded = try RouterScenarioFixture<DescriptorRoute>.decode(from: original.encode())
        let target = try RouterTestStore(initialState: initial, exhaustivity: .off)
        _ = try await RouterScenarioRunner.replay(decoded, on: target)
        #expect(target.state == initial)
        #expect(target.revision == 4)
        target.skipReceivedEvents()
        await target.finish()
        let generated = try RouterScenarioSourceGenerator.generateFiles(original, routeTypeName: "DescriptorRoute")
        #expect(try RouterScenarioFixture<DescriptorRoute>.decode(from: generated.fixtureData) == original)
        #expect(generated.source.contains("RouterScenarioFixture<DescriptorRoute>.decode"))
        #expect(try RouterScenarioSourceGenerator.generate(original, routeTypeName: "DescriptorRoute").contains("decode(from: data)"))
    }

    @Test("Runtime result and unknown authority survive export and reject replay", arguments: ["presentation.runtimeResultAuthority", "future.resultAuthority"])
    @MainActor
    func runtimeAuthorityNeverReplayed(code: String) async throws {
        let initial = try fixture().initialState
        let limitation = RouterScenarioReplayLimitation(rawValue: code)
        let original = RouterScenarioFixture(initialState: initial, steps: [
            .init(action: .dismissPresentation, context: .init(), replayLimitation: limitation,
                  observedState: initial, observedRevision: 0, observedTerminal: .unchanged,
                  expectation: .init(state: initial, revision: 0, terminal: .unchanged)),
        ])
        let decoded = try RouterScenarioFixture<DescriptorRoute>.decode(from: original.encode())
        #expect(decoded.steps[0].replayLimitation == limitation)
        let target = try RouterTestStore(initialState: initial, exhaustivity: .off)
        await #expect(throws: RouterScenarioReplayError.unsupportedRequestSemantics(step: 0, code: limitation)) {
            try await RouterScenarioRunner.replay(decoded, on: target)
        }
        #expect(target.state == initial)
        #expect(target.revision == 0)
        #expect(throws: RouterScenarioSourceGenerationError.unsupportedRequestSemantics(step: 0, code: limitation)) {
            try RouterScenarioSourceGenerator.generateFiles(decoded, routeTypeName: "DescriptorRoute")
        }
        await target.finish()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func replacing(_ data: Data, edit: (inout [String: Any]) throws -> Void) throws -> Data {
        var value = try object(data)
        try edit(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func editingStack(_ data: Data, edit: (inout [String: Any]) throws -> Void) throws -> Data {
        try replacing(data) { value in
            var state = try #require(value["initialState"] as? [String: Any])
            var root = try #require(state["root"] as? [String: Any])
            var stackCase = try #require(root["stack"] as? [String: Any])
            var stack = try #require(stackCase["_0"] as? [String: Any])
            try edit(&stack)
            stackCase["_0"] = stack; root["stack"] = stackCase
            state["root"] = root; value["initialState"] = state
        }
    }
}
