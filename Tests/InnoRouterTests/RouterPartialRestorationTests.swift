import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

@Suite("RouterPartialRestoration")
struct RouterPartialRestorationTests {
    private enum RouteFixture: String, Route, Codable {
        case home
        case detail
        case invalid
        case replacement
        case settings
    }

    @MainActor
    private final class ValidationGate {
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var hasEntered = false
        private(set) var hasExited = false

        func suspend() async {
            hasEntered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitUntilEntered() async {
            guard !hasEntered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func markExited() {
            hasExited = true
            let waiters = exitWaiters
            exitWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitUntilExited() async {
            guard !hasExited else { return }
            await withCheckedContinuation { exitWaiters.append($0) }
        }
    }

    @Test("Invalid routes are removed without discarding valid sibling scopes")
    @MainActor
    func preservesValidSubtreesAndReportsEveryChange() async throws {
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let tabs = try RouterContainerState<RouteFixture>(
            style: .tabs,
            selection: "main",
            branches: [
                .init(
                    id: "main",
                    node: .stack(
                        path: [.home, .invalid, .detail],
                        presentation: .init(route: .invalid, style: .sheet)
                    )
                ),
                .init(id: "settings", node: .stack(path: [.settings])),
            ],
            badges: ["settings": 2]
        )
        let snapshot = try RouterState(
            root: .container(tabs),
            windows: [
                .init(id: windowID, route: .invalid, node: .stack(path: [.detail])),
            ]
        )
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(snapshot)
        let store = RouterStore<RouteFixture>()
        let validator = RouterPartialRestorationValidator<RouteFixture> { route, location in
            guard route == .invalid else { return .keep }
            if location.role == .windowRoot {
                return .replace(with: .replacement, reason: "window-route-retired")
            }
            return .remove(reason: "route-no-longer-valid")
        }

        let outcome = try await store.restorePartially(
            from: data,
            using: codec,
            validator: validator
        )

        guard case .applied(_, _, let restored, 1) = outcome.transition,
              case .container(let restoredTabs) = restored.root else {
            Issue.record("Expected one applied partial-restoration transition")
            return
        }
        #expect(restoredTabs.selection == "main")
        #expect(restoredTabs.badges == ["settings": 2])
        #expect(restoredTabs.branches[0].node == .stack(path: [.home]))
        #expect(restoredTabs.branches[1].node == .stack(path: [.settings]))
        #expect(restored.windows.first?.route == .replacement)
        #expect(restored.windows.first?.node == .stack(path: [.detail]))
        #expect(outcome.report.entries.map(\.change) == [
            .kept,
            .removed,
            .removedDependentSuffix,
            .removed,
            .kept,
            .replaced,
            .kept,
        ])
        #expect(outcome.report.entries.map(\.reason) == [
            "validator-kept",
            "route-no-longer-valid",
            "invalid-predecessor",
            "route-no-longer-valid",
            "validator-kept",
            "window-route-retired",
            "validator-kept",
        ])
    }

    @Test("A state change during validation wins over the stale restoration")
    @MainActor
    func rejectsStaleValidatedSnapshot() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.home, .detail]))
        let store = RouterStore<RouteFixture>()
        let gate = ValidationGate()
        let validator = RouterPartialRestorationValidator<RouteFixture> { route, _ in
            if route == .home { await gate.suspend() }
            return .keep
        }

        let restoration = Task { @MainActor in
            try await store.restorePartially(
                from: data,
                using: codec,
                validator: validator
            )
        }
        await gate.waitUntilEntered()
        let foreground = await store.perform(.push(.settings))
        gate.release()
        let outcome = try await restoration.value

        guard case .applied = foreground,
              case .rejected(_, let current, 1, let reason) = outcome.transition else {
            Issue.record("Expected foreground navigation to reject stale restoration")
            return
        }
        #expect(reason == .staleState(expectedRevision: 0, actualRevision: 1))
        #expect(current.root == .stack(path: [.settings]))
        #expect(store.state == current)
    }

    @Test("Partial restoration uses the normal policy pipeline")
    @MainActor
    func policyCanRejectValidatedRestoration() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.home]))
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "restoration-lock") { transition in
                        transition.context.source == .restoration
                            ? .reject("locked")
                            : .allow
                    },
                ]
            )
        )
        let outcome = try await store.restorePartially(
            from: data,
            using: codec,
            validator: .init { _, _ in .keep }
        )

        #expect(outcome.report.entries.map(\.change) == [.kept])
        guard case .rejected(_, let state, 0, let reason) = outcome.transition else {
            Issue.record("Expected policy-rejected restoration")
            return
        }
        #expect(reason == .policy(name: "restoration-lock", message: "locked"))
        #expect(state == .rootStack)
        #expect(store.state == .rootStack)
    }

    @Test("A fully invalid required path fails unless the app supplies a validated fallback")
    @MainActor
    func requiredPathFallbackIsExplicitAndValidated() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.invalid]))
        let failingStore = RouterStore<RouteFixture>()

        await #expect(throws: RouterPartialRestorationError.missingRequiredPathFallback(.root)) {
            try await failingStore.restorePartially(
                from: data,
                using: codec,
                validator: .init { _, _ in .remove(reason: "retired") }
            )
        }
        #expect(failingStore.revision == 0)

        let recoveredStore = RouterStore<RouteFixture>()
        let outcome = try await recoveredStore.restorePartially(
            from: data,
            using: codec,
            validator: .init(
                fallback: { _ in .home },
                validate: { route, _ in
                    route == .invalid ? .remove(reason: "retired") : .keep
                }
            )
        )
        #expect(recoveredStore.state.root == .stack(path: [.home]))
        #expect(outcome.report.entries.map(\.change) == [.removed, .replaced])
        #expect(outcome.report.entries.last?.reason == "fallback-kept")
    }

    @Test("Fallback replacements are revalidated before restoration commits")
    @MainActor
    func fallbackReplacementMustBeValidated() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.invalid]))
        let store = RouterStore<RouteFixture>()
        var settingsValidationCount = 0
        let validator = RouterPartialRestorationValidator<RouteFixture>(
            fallback: { _ in .detail },
            validate: { route, _ in
                switch route {
                case .invalid: return .remove(reason: "deleted")
                case .detail: return .replace(with: .settings, reason: "migrated")
                case .settings:
                    settingsValidationCount += 1
                    return .remove(reason: "also-deleted")
                case .home, .replacement: return .keep
                }
            }
        )

        await #expect(throws: RouterPartialRestorationError.invalidPathFallback(.root)) {
            try await store.restorePartially(from: data, using: codec, validator: validator)
        }
        #expect(settingsValidationCount == 1)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Replacement cycles fail before restoration commits")
    @MainActor
    func replacementCycleFailsClosed() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.home]))
        let store = RouterStore<RouteFixture>()

        await #expect(throws: RouterPartialRestorationError.self) {
            try await store.restorePartially(
                from: data,
                using: codec,
                validator: .init { route, _ in
                    route == .home
                        ? .replace(with: .detail, reason: "first")
                        : .replace(with: .home, reason: "cycle")
                }
            )
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Cancellation stops validation before the next route")
    @MainActor
    func cancelStopsSubsequentValidationCalls() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.home, .detail, .settings]))
        let store = RouterStore<RouteFixture>()
        let gate = ValidationGate()
        var validated: [RouteFixture] = []
        let restoration = Task { @MainActor in
            try await store.restorePartially(
                from: data,
                using: codec,
                validator: .init { route, _ in
                    validated.append(route)
                    if route == .home {
                        await gate.suspend()
                        gate.markExited()
                    }
                    return .keep
                }
            )
        }

        await gate.waitUntilEntered()
        restoration.cancel()
        do {
            _ = try await restoration.value
            Issue.record("Expected cancellation")
        } catch let error as RouterPartialRestorationError {
            #expect(error == .cancelled)
        }
        gate.release()
        await gate.waitUntilExited()

        #expect(validated == [.home])
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }
}
