import Foundation
import Testing

import InnoRouterCore

@Suite("Router reducer state machine")
struct RouterStateMachineTests {
    private enum FixtureRoute: String, Route, Codable, CaseIterable {
        case home
        case detail
        case settings
        case editor
        case profile
    }

    private struct RunResult: Equatable {
        let state: RouterState<FixtureRoute>
        let acceptedCount: Int
        let rejectedCount: Int
    }

    @Test("Fixed-seed action sequences preserve every canonical invariant")
    func randomizedReducerSequences() throws {
        let seeds: [UInt64] = [
            0x0000_0000_0000_0001,
            0x0123_4567_89AB_CDEF,
            0xA11C_E5EED,
            0xDEAD_BEEF_CAFE_BABE,
        ]

        for seed in seeds {
            let first = try run(seed: seed, stepCount: 1_000)
            let replay = try run(seed: seed, stepCount: 1_000)

            #expect(first == replay, "seed \(seed) must replay exactly")
            #expect(first.acceptedCount > 100)
            #expect(first.rejectedCount > 100)
            try first.state.validate()
        }
    }

    @Test("Long randomized states survive deterministic snapshot round trips")
    func randomizedSnapshotRoundTrips() throws {
        let codec = try RouterSnapshotCodec<FixtureRoute>(currentVersion: 1)

        for seed in 10..<30 {
            let result = try run(seed: UInt64(seed), stepCount: 300)
            let firstEncoding = try codec.encode(result.state)
            let restored = try codec.decode(firstEncoding)
            let secondEncoding = try codec.encode(restored)

            #expect(restored == result.state)
            #expect(secondEncoding == firstEncoding)
        }
    }

    private func run(seed: UInt64, stepCount: Int) throws -> RunResult {
        var generator = DeterministicGenerator(seed: seed)
        var state = try initialState()
        var acceptedCount = 0
        var rejectedCount = 0

        for _ in 0..<stepCount {
            let action = makeAction(using: &generator, state: state)
            let before = state
            do {
                let next = try RouterReducer.reduce(action, from: state)
                try next.validate()
                state = next
                acceptedCount += 1
            } catch is RouterMutationError {
                // Reduction is value-semantic: a failed candidate cannot leak
                // any partially applied mutation back into authority state.
                #expect(state == before)
                rejectedCount += 1
            } catch {
                Issue.record("Unexpected reducer error: \(error)")
                throw error
            }
        }

        return RunResult(
            state: state,
            acceptedCount: acceptedCount,
            rejectedCount: rejectedCount
        )
    }

    private func initialState() throws -> RouterState<FixtureRoute> {
        let split = try RouterContainerState<FixtureRoute>(
            style: .split,
            branches: [
                RouterBranch(id: "sidebar"),
                RouterBranch(id: "detail"),
            ],
            split: try RouterSplitState()
        )
        let tabs = try RouterContainerState<FixtureRoute>(
            style: .tabs,
            selection: "home",
            branches: [
                RouterBranch(id: "home"),
                RouterBranch(id: "advanced", node: .container(split)),
            ]
        )
        return try RouterState(root: .container(tabs))
    }

    private func makeAction(
        using generator: inout DeterministicGenerator,
        state: RouterState<FixtureRoute>
    ) -> RouterAction<FixtureRoute> {
        let route = FixtureRoute.allCases[generator.index(upperBound: FixtureRoute.allCases.count)]
        let homePath = RouterScopePath(["home"])
        let detailPath = RouterScopePath(["advanced", "detail"])
        let sidebarPath = RouterScopePath(["advanced", "sidebar"])
        let windowID = Self.windowIDs[generator.index(upperBound: Self.windowIDs.count)]
        let immersiveID = state.immersiveSpace?.id ?? "space-\(generator.index(upperBound: 3))"

        switch generator.index(upperBound: 25) {
        case 0:
            return .push(route).inScope(homePath)
        case 1:
            return .pushIfNeeded(route).inScope(homePath)
        case 2:
            return .backOrPush(route).inScope(homePath)
        case 3:
            return .replaceTop(route).inScope(detailPath)
        case 4:
            return .pushMany([route, .detail]).inScope(sidebarPath)
        case 5:
            return .pop(count: generator.index(upperBound: 8) - 1).inScope(homePath)
        case 6:
            return .popTo(route).inScope(detailPath)
        case 7:
            return .popToRoot.inScope(sidebarPath)
        case 8:
            return .replaceStack(generator.routes(maximumCount: 5)).inScope(detailPath)
        case 9:
            return .present(
                RouterPresentation(
                    id: Self.presentationIDs[generator.index(upperBound: Self.presentationIDs.count)],
                    route: route,
                    style: .sheet,
                    options: .init(detents: [.medium, .large], selectedDetent: .medium)
                )
            ).inScope(homePath)
        case 10:
            return .dismissPresentation.inScope(homePath)
        case 11:
            return .setPresentationDetent(.large).inScope(homePath)
        case 12:
            return .select(generator.boolean() ? "home" : "missing")
        case 13:
            return .setBadge(generator.index(upperBound: 6) - 2, for: "home")
        case 14:
            return .clearAllBadges
        case 15:
            return .setSplitVisibility(.doubleColumn).inScope("advanced")
        case 16:
            return .setPreferredCompactColumn(
                generator.boolean() ? .sidebar : .content
            ).inScope("advanced")
        case 17:
            return .openWindow(.init(id: windowID, route: route))
        case 18:
            return .dismissWindow(windowID)
        case 19:
            return .push(route).inScope(.window(windowID))
        case 20:
            return .enterImmersiveSpace(.init(id: immersiveID, route: route))
        case 21:
            return .dismissImmersiveSpace
        case 22:
            return .push(route).inScope(.immersiveSpace(immersiveID))
        case 23:
            return .push(route).inScope("missing")
        default:
            return .apply(.init(state: state))
        }
    }

    private static let windowIDs: [UUID] = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
    ]

    private static let presentationIDs: [UUID] = [
        UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
    ]
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func boolean() -> Bool {
        next().isMultiple(of: 2)
    }

    mutating func routes<RouteType: CaseIterable>(
        maximumCount: Int
    ) -> [RouteType] where RouteType.AllCases: RandomAccessCollection {
        let allCases = RouteType.allCases
        let count = index(upperBound: maximumCount + 1)
        return (0..<count).map { _ in
            let offset = index(upperBound: allCases.count)
            return allCases[allCases.index(allCases.startIndex, offsetBy: offset)]
        }
    }
}
