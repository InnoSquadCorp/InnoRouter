// MARK: - StatePersistenceTests.swift
// InnoRouterTests - StatePersistence Data <-> value round-trips
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum PersistRoute: String, Route, Codable {
    case root
    case profile
    case settings
    case onboarding
}

@Suite("StatePersistence Tests")
struct StatePersistenceTests {

    @Test("FlowPlan round-trips through StatePersistence")
    func flowPlanRoundTrip() throws {
        let persistence = StatePersistence<PersistRoute>()
        let original = FlowPlan<PersistRoute>(steps: [
            .push(.root),
            .push(.profile),
            .sheet(.settings),
        ])

        let data = try persistence.encode(original)
        let restored = try persistence.decode(data)

        #expect(restored == original)
    }

    @Test("RouteStack round-trips through StatePersistence")
    func routeStackRoundTrip() throws {
        let persistence = StatePersistence<PersistRoute>()
        let original = try RouteStack<PersistRoute>(validating: [.root, .profile])

        let data = try persistence.encode(original)
        let restored = try persistence.decodeStack(data)

        #expect(restored == original)
    }

    @Test("Empty FlowPlan round-trips without side effects")
    func emptyFlowPlanRoundTrip() throws {
        let persistence = StatePersistence<PersistRoute>()

        let data = try persistence.encode(FlowPlan<PersistRoute>())
        let restored = try persistence.decode(data)

        #expect(restored.steps.isEmpty)
    }

    @Test("FlowStore.apply(decoded) reproduces the original path")
    @MainActor
    func flowStoreApplyAfterDecodeReproducesPath() throws {
        let persistence = StatePersistence<PersistRoute>()
        let original = FlowPlan<PersistRoute>(steps: [
            .push(.root),
            .push(.profile),
            .sheet(.onboarding),
        ])

        let data = try persistence.encode(original)
        let restored = try persistence.decode(data)

        let store = FlowStore<PersistRoute>()
        store.apply(restored)

        #expect(store.path == original.steps)
        #expect(store.navigationStore.state.path == [.root, .profile])
        #expect(store.modalStore.currentPresentation?.route == .onboarding)
    }

    @Test("Malformed JSON surfaces as DecodingError")
    func malformedJSONThrowsDecodingError() {
        let persistence = StatePersistence<PersistRoute>()
        let garbage = Data("not json".utf8)

        #expect(throws: DecodingError.self) {
            _ = try persistence.decode(garbage)
        }
    }

    @Test("Custom encoder configuration is preserved (sortedKeys)")
    func customEncoderConfigurationIsPreserved() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let persistence = StatePersistence<PersistRoute>(encoder: encoder)
        let plan = FlowPlan<PersistRoute>(steps: [.push(.root), .sheet(.settings)])

        let data1 = try persistence.encode(plan)
        let data2 = try persistence.encode(plan)

        // Sorted keys => byte-deterministic output for identical inputs.
        #expect(data1 == data2)
    }

    @Test("StateRestorationAdapter restores a navigation stack snapshot")
    @MainActor
    func adapterRestoresNavigationStack() throws {
        let source = try NavigationStore<PersistRoute>(initialPath: [.root, .profile])
        let target = NavigationStore<PersistRoute>()
        let adapter = StateRestorationAdapter<PersistRoute>()

        let data = try adapter.snapshotNavigationStack(from: source)
        let restored = adapter.restoreNavigationStack(from: data, into: target)

        #expect(restored)
        #expect(target.state.path == [.root, .profile])
    }

    @Test("StateRestorationAdapter reports navigation decode failure without empty fallback")
    @MainActor
    func adapterReportsNavigationDecodeFailure() throws {
        let failures = Mutex<[StateRestorationFailure]>([])
        let store = try NavigationStore<PersistRoute>(initialPath: [.root])
        let adapter = StateRestorationAdapter<PersistRoute> { failure in
            failures.withLock { $0.append(failure) }
        }

        let restored = adapter.restoreNavigationStack(from: Data("not json".utf8), into: store)

        #expect(!restored)
        #expect(store.state.path == [.root])
        #expect(failures.withLock { $0.map(\.target) } == [.navigationStack])
    }

    @Test("StateRestorationAdapter applies the store route stack validator")
    @MainActor
    func adapterAppliesNavigationStackValidator() throws {
        let failures = Mutex<[StateRestorationFailure]>([])
        let validator = RouteStackValidator<PersistRoute>
            .rooted(at: .root)
            .combined(with: .uniqueRoutes)
        let store = try NavigationStore<PersistRoute>(
            initialPath: [.root],
            configuration: NavigationStoreConfiguration(routeStackValidator: validator)
        )
        let persistence = StatePersistence<PersistRoute>()
        let adapter = StateRestorationAdapter<PersistRoute> { failure in
            failures.withLock { $0.append(failure) }
        }

        for invalidPath in [
            [PersistRoute.settings],
            [.root, .profile, .profile],
        ] {
            let data = try persistence.encode(RouteStack(path: invalidPath))

            #expect(!adapter.restoreNavigationStack(from: data, into: store))
            #expect(store.state.path == [.root])
        }

        #expect(failures.withLock { $0.map(\.target) } == [
            .navigationStack,
            .navigationStack,
        ])
    }

    @Test("StateRestorationAdapter reports navigation apply rejection")
    @MainActor
    func adapterReportsNavigationApplyRejection() throws {
        let failures = Mutex<[StateRestorationFailure]>([])
        let adapter = StateRestorationAdapter<PersistRoute> { failure in
            failures.withLock { $0.append(failure) }
        }
        let source = try NavigationStore<PersistRoute>(initialPath: [.root, .profile])
        let rejectingStore = try NavigationStore<PersistRoute>(
            initialPath: [.settings],
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(
                            willExecute: { command, _ in
                                .cancel(.middleware(debugName: "restore-blocker", command: command))
                            }
                        ),
                        debugName: "restore-blocker"
                    )
                ]
            )
        )

        let data = try adapter.snapshotNavigationStack(from: source)
        let restored = adapter.restoreNavigationStack(from: data, into: rejectingStore)

        #expect(!restored)
        #expect(rejectingStore.state.path == [.settings])
        #expect(failures.withLock { $0.map(\.target) } == [.navigationStack])
    }

    @Test("StateRestorationAdapter restores a FlowPlan snapshot")
    @MainActor
    func adapterRestoresFlowPlan() throws {
        let source = FlowStore<PersistRoute>()
        source.apply(
            FlowPlan(steps: [
                .push(.root),
                .push(.profile),
                .sheet(.onboarding),
            ])
        )
        let target = FlowStore<PersistRoute>()
        let adapter = StateRestorationAdapter<PersistRoute>()

        let data = try adapter.snapshotFlowPlan(from: source)
        let restored = adapter.restoreFlowPlan(from: data, into: target)

        #expect(restored)
        #expect(target.path == [.push(.root), .push(.profile), .sheet(.onboarding)])
    }

    @Test("StateRestorationAdapter reports FlowPlan apply rejection")
    @MainActor
    func adapterReportsFlowPlanApplyRejection() throws {
        let failures = Mutex<[StateRestorationFailure]>([])
        let adapter = StateRestorationAdapter<PersistRoute> { failure in
            failures.withLock { $0.append(failure) }
        }
        let plan = FlowPlan<PersistRoute>(steps: [.push(.root)])
        let data = try StatePersistence<PersistRoute>().encode(plan)
        let rejectingStore = FlowStore<PersistRoute>(
            configuration: FlowStoreConfiguration(
                navigation: NavigationStoreConfiguration(
                    middlewares: [
                        .init(
                            middleware: AnyNavigationMiddleware(
                                willExecute: { command, _ in
                                    .cancel(.middleware(debugName: "restore-blocker", command: command))
                                }
                            ),
                            debugName: "restore-blocker"
                        )
                    ]
                )
            )
        )

        let restored = adapter.restoreFlowPlan(from: data, into: rejectingStore)

        #expect(!restored)
        #expect(rejectingStore.path.isEmpty)
        #expect(failures.withLock { $0.map(\.target) } == [.flowPlan])
    }
}
