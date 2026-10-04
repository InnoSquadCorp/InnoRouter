import Foundation
import Testing

import InnoRouterCore
#if canImport(InnoRouterRestorationContracts)
@testable import InnoRouterRestorationContracts
#else
@testable import InnoRouterSwiftUI
#endif

private enum PlannerRoute: Route, Codable {
    case step(Int)
    case secret(String)
}

@MainActor
private final class PlannerVisits {
    var routes: [PlannerRoute] = []
    var locations: [RouterRestorationRouteLocation] = []
    var fallbackScopes: [RouterScopePath] = []

    func record(_ route: PlannerRoute, at location: RouterRestorationRouteLocation) {
        routes.append(route)
        locations.append(location)
    }
}

@MainActor
private func makePlan(
    _ state: RouterState<PlannerRoute>,
    validator: RouterPartialRestorationValidator<PlannerRoute>
) async throws -> (RouterState<PlannerRoute>, RouterPartialRestorationReport) {
    try await preparePartialRestoration(state, validator: validator, operations: .init(maximumCount: 8), timeout: nil, sleep: { _ in })
}

@Suite("Production partial-restoration planner contracts", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterPartialRestorationPlannerContractTests {
    private let outerID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    private let innerID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
    private let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!

    @Test("Keep-all is an exact value-preserving positive control")
    func unchangedPositiveControl() async throws {
        let source = try RouterState<PlannerRoute>(
            root: .stack(path: [.step(0)], presentation: .init(
                id: outerID, route: .step(1), style: .sheet,
                options: .init(detents: [.medium, .large], selectedDetent: .medium),
                node: .stack(path: [.step(2)])
            )),
            windows: [.init(id: windowID, route: .step(3), node: .stack(path: [.step(4)]))],
            immersiveSpace: .init(id: "space", route: .step(5), node: .stack(path: [.step(6)]))
        )
        let result = try await makePlan(source, validator: .init { _, _ in .keep })
        #expect(result.0 == source)
        #expect(result.1.entries.count == 7)
        #expect(result.1.entries.allSatisfy { $0.change == .kept && $0.reason == "validator-kept" })
        #expect(result.1.topologyChanges.isEmpty)
    }

    @Test("Nested retained presentations validate children at exact typed boundaries")
    func retainedNestedPresentationLocations() async throws {
        let inner = RouterPresentation<PlannerRoute>(
            id: innerID, route: .step(3), style: .popover, node: .stack(path: [.step(4)])
        )
        let container = try RouterContainerState<PlannerRoute>(
            style: .custom("nested"), branches: [
                .init(id: "child", node: .stack(path: [.step(2)], presentation: inner)),
            ]
        )
        let source = try RouterState<PlannerRoute>(root: .stack(
            path: [.step(0)], presentation: .init(
                id: outerID, route: .step(1), style: .sheet, node: .container(container)
            )
        ))
        let visits = PlannerVisits()
        let result = try await makePlan(source, validator: .init { route, location in
            visits.record(route, at: location)
            return route == .step(3) ? .replace(with: .step(30), reason: "renamed") : .keep
        })
        let child = RouterScopePath.root.appendingPresentation(outerID).appending("child")
        let innerChild = child.appendingPresentation(innerID)
        #expect(visits.routes == [.step(0), .step(1), .step(2), .step(3), .step(30), .step(4)])
        #expect(visits.locations == [
            .init(scope: .root, role: .path, index: 0),
            .init(scope: .root, role: .presentation),
            .init(scope: child, role: .path, index: 0),
            .init(scope: child, role: .presentation),
            .init(scope: child, role: .presentation),
            .init(scope: innerChild, role: .path, index: 0),
        ])
        #expect(result.0.node(at: innerChild) == .stack(path: [.step(4)]))
        let restored = try #require(result.0.node(at: child))
        guard case .stack(let stack) = restored else { Issue.record("Expected child stack"); return }
        #expect(stack.presentation?.route == .step(30))
        #expect(stack.presentation?.id == innerID)
        #expect(stack.presentation?.style == .popover)
        #expect(result.1.entries.map(\.change) == [.kept, .kept, .kept, .replaced, .kept])
        #expect(result.1.entries.last?.location == .init(scope: innerChild, role: .path, index: 0))
        // A branch with the same printed presentation name is still a different boundary.
        #expect(innerChild != child.appending(RouterScopeID("presentation[\(innerID.uuidString)]")))
    }

    @Test("Removing a presentation suppresses every descendant validator and fallback")
    func removedPresentationSuppressesDescendants() async throws {
        let source = try RouterState<PlannerRoute>(root: .stack(
            path: [.step(0)], presentation: .init(
                id: outerID, route: .step(1), style: .sheet,
                node: .stack(path: [.step(2)], presentation: .init(
                    id: innerID, route: .step(3), style: .sheet, node: .stack(path: [.step(4)])
                ))
            )
        ))
        let visits = PlannerVisits()
        let result = try await makePlan(source, validator: .init(
            fallback: { scope in visits.fallbackScopes.append(scope); return .step(99) },
            validate: { route, location in
                visits.record(route, at: location)
                return route == .step(1) ? .remove(reason: "deleted") : .keep
            }
        ))
        #expect(result.0 == .rootStack(path: [.step(0)]))
        #expect(visits.routes == [.step(0), .step(1)])
        #expect(visits.fallbackScopes.isEmpty)
        #expect(result.1.entries.map(\.change) == [.kept, .removed])
    }

    @Test("Removed window and immersive roots suppress descendants but preserve independent siblings")
    func removedSceneRootsSuppressDescendants() async throws {
        let retainedWindow = UUID(uuidString: "00000000-0000-0000-0000-000000000704")!
        let source = try RouterState<PlannerRoute>(
            root: .stack(path: [.step(0)]),
            windows: [
                .init(id: windowID, route: .step(1), node: .stack(path: [.step(2)])),
                .init(id: retainedWindow, route: .step(3), node: .stack(path: [.step(4)])),
            ],
            immersiveSpace: .init(id: "space", route: .step(5), node: .stack(path: [.step(6)]))
        )
        let visits = PlannerVisits()
        let result = try await makePlan(source, validator: .init { route, location in
            visits.record(route, at: location)
            return [.step(1), .step(5)].contains(route) ? .remove(reason: "retired") : .keep
        })
        #expect(visits.routes == [.step(0), .step(1), .step(3), .step(4), .step(5)])
        #expect(result.0.windows == [source.windows[1]])
        #expect(result.0.immersiveSpace == nil)
        #expect(result.1.entries[1].location == .init(scope: .window(windowID), role: .windowRoot))
        #expect(result.1.entries.last?.location == .init(scope: .immersiveSpace("space"), role: .immersiveSpaceRoot))
    }

    @Test("Retained scene descendants retain scene domains through presentation boundaries")
    func retainedSceneDomains() async throws {
        let source = try RouterState<PlannerRoute>(
            windows: [.init(id: windowID, route: .step(0), node: .stack(presentation: .init(
                id: outerID, route: .step(1), style: .sheet, node: .stack(path: [.step(2)])
            )))],
            immersiveSpace: .init(id: "space", route: .step(3), node: .stack(presentation: .init(
                id: innerID, route: .step(4), style: .sheet, node: .stack(path: [.step(5)])
            )))
        )
        let visits = PlannerVisits()
        let result = try await makePlan(source, validator: .init { route, location in
            visits.record(route, at: location)
            return route == .step(0) ? .replace(with: .step(10), reason: "new-root") : .keep
        })
        #expect(result.0.windows.first?.route == .step(10))
        #expect(result.0.windows.first?.node == source.windows.first?.node)
        #expect(visits.locations[3] == .init(scope: .window(windowID).appendingPresentation(outerID), role: .path, index: 0))
        #expect(visits.locations.last == .init(scope: .immersiveSpace("space").appendingPresentation(innerID), role: .path, index: 0))
    }

    @Test("Reports identify keep/remove/replace without embedding route payload")
    func reportLocationsAndPayloadExclusion() async throws {
        let source = try RouterState<PlannerRoute>(root: .stack(
            path: [.secret("private-kept"), .secret("private-old"), .secret("private-removed")],
            presentation: .init(id: outerID, route: .secret("private-modal"), style: .sheet)
        ))
        let result = try await makePlan(source, validator: .init { route, _ in
            switch route {
            case .secret("private-old"): .replace(with: .secret("private-new"), reason: "renamed")
            case .secret("private-removed"), .secret("private-modal"): .remove(reason: "retired")
            default: .keep
            }
        })
        #expect(result.1.entries.map(\.change) == [.kept, .replaced, .removed, .removed])
        #expect(result.1.entries.map(\.reason) == ["validator-kept", "renamed", "retired", "retired"])
        #expect(result.1.entries.map(\.location) == [
            .init(scope: .root, role: .path, index: 0),
            .init(scope: .root, role: .path, index: 1),
            .init(scope: .root, role: .path, index: 2),
            .init(scope: .root, role: .presentation),
        ])
        let encoded = try JSONEncoder().encode(result.1)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("private-"))
        #expect(try JSONDecoder().decode(RouterPartialRestorationReport.self, from: encoded) == result.1)
    }

    @Test("Application reason strings are preserved and are not a sanitization boundary")
    func customReasonIsAppOwned() async throws {
        let source = try RouterState<PlannerRoute>(root: .stack(presentation: .init(route: .step(0), style: .sheet)))
        let result = try await makePlan(source, validator: .init { _, _ in .remove(reason: "caller-provided-text") })
        #expect(result.1.entries.first?.reason == "caller-provided-text")
    }

    @Test("A removed path route drops its dependent suffix without validating it")
    func dependentSuffixAndSiblingPreservation() async throws {
        let source = try RouterState<PlannerRoute>(root: .container(try .init(
            style: .tabs, selection: "main", branches: [
                .init(id: "main", node: .stack(path: [.step(0), .step(1), .step(2)],
                    presentation: .init(id: outerID, route: .step(3), style: .sheet))),
                .init(id: "other", node: .stack(path: [.step(4)])),
            ], badges: ["other": 7]
        )))
        let visits = PlannerVisits()
        let result = try await makePlan(source, validator: .init { route, location in
            visits.record(route, at: location)
            return route == .step(1) ? .remove(reason: "retired") : .keep
        })
        #expect(visits.routes == [.step(0), .step(1), .step(3), .step(4)])
        #expect(result.1.entries[2] == .init(location: .init(scope: ["main"], role: .path, index: 2),
            change: .removedDependentSuffix, reason: "invalid-predecessor"))
        #expect(result.0.node(at: ["other"]) == source.node(at: ["other"]))
        guard case .container(let tabs) = result.0.root else { Issue.record("Expected tabs"); return }
        #expect(tabs.selection == "main")
        #expect(tabs.badges == ["other": 7])
    }

    @Test("An originally empty stack requires no fallback or validation")
    func emptyPathPositiveControl() async throws {
        let visits = PlannerVisits()
        let result = try await makePlan(.rootStack, validator: .init(
            fallback: { scope in visits.fallbackScopes.append(scope); return .step(1) },
            validate: { route, location in visits.record(route, at: location); return .keep }
        ))
        #expect(result.0 == .rootStack)
        #expect(result.1.entries.isEmpty)
        #expect(visits.routes.isEmpty && visits.fallbackScopes.isEmpty)
    }

    @Test("Removing an entire nonempty path requires an explicit fallback")
    func missingFallbackFailsClosed() async throws {
        await #expect(throws: RouterPartialRestorationError.missingRequiredPathFallback(.root)) {
            try await makePlan(.rootStack(path: [.step(0), .step(1)]), validator: .init { _, _ in .remove(reason: "retired") })
        }
    }

    @Test("Fallback is revalidated and its replacements retain the exact child scope")
    func fallbackReplacementIsRevalidated() async throws {
        let child = RouterScopePath.root.appendingPresentation(outerID)
        let source = try RouterState<PlannerRoute>(root: .stack(presentation: .init(
            id: outerID, route: .step(0), style: .sheet, node: .stack(path: [.step(1), .step(2)])
        )))
        let visits = PlannerVisits()
        let result = try await makePlan(source, validator: .init(
            fallback: { scope in visits.fallbackScopes.append(scope); return .step(3) },
            validate: { route, location in
                visits.record(route, at: location)
                return switch route {
                case .step(1): .remove(reason: "retired")
                case .step(3): .replace(with: .step(4), reason: "migrated")
                default: .keep
                }
            }
        ))
        #expect(visits.routes == [.step(0), .step(1), .step(3), .step(4)])
        #expect(visits.fallbackScopes == [child])
        #expect(result.0.node(at: child) == .stack(path: [.step(4)]))
        #expect(result.1.entries.last == .init(location: .init(scope: child, role: .path, index: 0),
            change: .replaced, reason: "fallback-replaced"))
    }

    @Test("Rejected fallback and rejected fallback replacement both fail closed", arguments: [false, true])
    func invalidFallbackFailsClosed(replacement: Bool) async throws {
        let visits = PlannerVisits()
        await #expect(throws: RouterPartialRestorationError.invalidPathFallback(.root)) {
            try await makePlan(.rootStack(path: [.step(0)]), validator: .init(
                fallback: { _ in .step(1) },
                validate: { route, location in
                    visits.record(route, at: location)
                    if replacement, route == .step(1) { return .replace(with: .step(2), reason: "migrated") }
                    return .remove(reason: "retired")
                }
            ))
        }
        #expect(visits.routes == (replacement ? [.step(0), .step(1), .step(2)] : [.step(0), .step(1)]))
    }

    @Test("Replacement cycles and self-replacements fail at the original location", arguments: [false, true])
    func replacementCyclesFailClosed(selfCycle: Bool) async throws {
        let location = RouterRestorationRouteLocation(scope: .root, role: .path, index: 0)
        let visits = PlannerVisits()
        await #expect(throws: RouterPartialRestorationError.replacementCycle(location)) {
            try await makePlan(.rootStack(path: [.step(0)]), validator: .init { route, place in
                visits.record(route, at: place)
                return .replace(with: selfCycle || route == .step(1) ? .step(0) : .step(1), reason: "cycle")
            })
        }
        #expect(visits.routes == (selfCycle ? [.step(0)] : [.step(0), .step(1)]))
        #expect(visits.locations.allSatisfy { $0 == location })
    }

    @Test("Exactly eight replacement edges may resolve to a kept route")
    func replacementEightEdgePositiveControl() async throws {
        let visits = PlannerVisits()
        let result = try await makePlan(.rootStack(path: [.step(0)]), validator: .init { route, location in
            visits.record(route, at: location)
            guard case .step(let value) = route, value < 8 else { return .keep }
            return .replace(with: .step(value + 1), reason: "step-\(value)")
        })
        #expect(visits.routes == (0...8).map(PlannerRoute.step))
        #expect(result.0 == .rootStack(path: [.step(8)]))
        #expect(result.1.entries.map(\.reason) == ["step-7"])
    }

    @Test("A ninth replacement edge is rejected before its route can run")
    func replacementNinthEdgeIsRejected() async throws {
        let visits = PlannerVisits()
        let location = RouterRestorationRouteLocation(scope: .root, role: .path, index: 0)
        await #expect(throws: RouterPartialRestorationError.replacementLimitExceeded(location, maximum: 8)) {
            try await makePlan(.rootStack(path: [.step(0)]), validator: .init { route, place in
                visits.record(route, at: place)
                guard case .step(let value) = route else { return .keep }
                return .replace(with: .step(value + 1), reason: "next")
            })
        }
        #expect(visits.routes == (0...8).map(PlannerRoute.step))
    }
}

@MainActor
private final class PlannerLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class PlannerNoncooperativeGate {
    let entered = PlannerLatch()
    let released = PlannerLatch()
    let exited = PlannerLatch()
    private(set) var hasExited = false
    private(set) var wasCancelled = false

    func suspend() async {
        entered.open()
        // Deliberately ignores cancellation until the test explicitly releases it.
        await released.wait()
        wasCancelled = Task.isCancelled
        hasExited = true
        exited.open()
    }
}

@Suite("Production planner completion races", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterPartialRestorationRaceContractTests {
    @Test("Value, timeout, and cancellation each win once; losing tasks are drained", arguments: ["value", "timeout", "cancel"])
    func competingTerminals(winner: String) async throws {
        let source = RouterState<PlannerRoute>.rootStack(path: [.step(0), .step(1)])
        let validation = PlannerNoncooperativeGate()
        let timer = PlannerNoncooperativeGate()
        var terminalCount = 0
        var successCount = 0
        let task = Task { @MainActor in
            defer { terminalCount += 1 }
            let result = try await preparePartialRestoration(source, validator: .init { route, _ in
                if route == .step(0) { return .replace(with: .step(10), reason: "migrated") }
                if route == .step(1) { await validation.suspend() }
                return .keep
            }, operations: .init(maximumCount: 8), timeout: .seconds(30), sleep: { _ in await timer.suspend() })
            successCount += 1
            return result
        }
        await validation.entered.wait()
        await timer.entered.wait()
        switch winner {
        case "value": validation.released.open()
        case "timeout": timer.released.open()
        default: task.cancel()
        }
        let result = await task.result
        switch result {
        case .success(let value):
            #expect(winner == "value")
            #expect(value.0 == .rootStack(path: [.step(10), .step(1)]))
            #expect(value.1.entries.count == 2)
        case .failure(let error):
            #expect(error as? RouterPartialRestorationError == (winner == "timeout" ? .validationTimedOut : .cancelled))
        }
        #expect(terminalCount == 1)
        #expect(successCount == (winner == "value" ? 1 : 0))
        if winner != "value" { #expect(!validation.hasExited) }
        // Deliver every losing completion after the first terminal. A second
        // checked-continuation resume would trap rather than pass this test.
        task.cancel()
        timer.released.open()
        validation.released.open()
        await timer.exited.wait()
        await validation.exited.wait()
        #expect(terminalCount == 1)
        #expect(successCount == (winner == "value" ? 1 : 0))
        if winner != "value" { #expect(validation.wasCancelled) }
        switch (result, await task.result) {
        case (.success(let before), .success(let after)): #expect(before.0 == after.0 && before.1 == after.1)
        case (.failure(let before), .failure(let after)):
            #expect(before as? RouterPartialRestorationError == after as? RouterPartialRestorationError)
        default: Issue.record("A late completion changed the observed terminal")
        }
        #expect(source == .rootStack(path: [.step(0), .step(1)]))
    }

    @Test("Cancellation before planning skips all application callbacks")
    func cancellationBeforeStart() async throws {
        var calls = 0
        let task = Task { @MainActor in
            try await makePlan(.rootStack(path: [.step(0)]), validator: .init { _, _ in calls += 1; return .keep })
        }
        // No MainActor suspension has occurred since task creation.
        task.cancel()
        await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
        #expect(calls == 0)
    }

    @Test("Cancellation during fallback returns no partial candidate or report")
    func cancellationDuringFallback() async throws {
        let gate = PlannerNoncooperativeGate()
        var routes: [PlannerRoute] = []
        var successes = 0
        let task = Task { @MainActor in
            let result = try await makePlan(.rootStack(path: [.step(0)]), validator: .init(
                fallback: { _ in await gate.suspend(); return .step(1) },
                validate: { route, _ in routes.append(route); return .remove(reason: "retired") }
            ))
            successes += 1
            return result
        }
        await gate.entered.wait()
        task.cancel()
        await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
        #expect(successes == 0)
        #expect(!gate.hasExited)
        gate.released.open()
        await gate.exited.wait()
        #expect(gate.wasCancelled)
        #expect(routes == [.step(0)])
        #expect(successes == 0)
    }
}
