// MARK: - NavigationPropertyBasedTests.swift
// InnoRouterTests - seed-parameterised invariants on NavigationCommand
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouter

private enum PBTRoute: String, Route {
    case home
    case detail
    case settings
    case profile
}

/// Minimal xorshift PRNG so property tests are reproducible from a
/// seed. Mirrors the established pattern in NavigationCommandTests but
/// scoped to this file to avoid cross-file coupling.
private struct PBTGenerator {
    private var state: UInt64

    init(seed: Int) {
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : UInt64(bitPattern: Int64(seed))
    }

    mutating func nextInt(upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % max(upperBound, 1)
    }

    mutating func nextRoute() -> PBTRoute {
        let routes: [PBTRoute] = [.home, .detail, .settings, .profile]
        return routes[nextInt(upperBound: routes.count)]
    }
}

/// Builds a "simple" (non-recursive) random command. Restricts the
/// space to non-indirect cases so generated sequences stay flat and
/// easy to reason about.
@MainActor
private func randomSimpleCommand(
    rng: inout PBTGenerator,
    currentPath: [PBTRoute]
) -> NavigationCommand<PBTRoute> {
    switch rng.nextInt(upperBound: 6) {
    case 0:
        return .push(rng.nextRoute())
    case 1:
        return .pushAll([rng.nextRoute(), rng.nextRoute()])
    case 2:
        return .pop
    case 3:
        if !currentPath.isEmpty {
            return .popTo(currentPath[rng.nextInt(upperBound: currentPath.count)])
        }
        return .pop
    case 4:
        return .popToRoot
    default:
        return .replace([rng.nextRoute()])
    }
}

@Suite("Navigation property-based tests")
struct NavigationPropertyBasedTests {

    @Test(
        "Compositionality: .sequence([c1, c2]) == apply(c1) then apply(c2)",
        arguments: Array(0..<100)
    )
    @MainActor
    func sequenceCompositionality(seed: Int) {
        var rng = PBTGenerator(seed: seed)
        let engine = NavigationEngine<PBTRoute>()

        // Start from a non-trivial stack so pop-style commands have
        // somewhere to work.
        var flatState = RouteStack<PBTRoute>(path: [.home, .detail, .settings])
        var seqState = flatState

        let c1 = randomSimpleCommand(rng: &rng, currentPath: flatState.path)
        let c2 = randomSimpleCommand(rng: &rng, currentPath: flatState.path)

        // Apply independently.
        _ = engine.apply(c1, to: &flatState)
        _ = engine.apply(c2, to: &flatState)

        // Apply via sequence.
        _ = engine.apply(.sequence([c1, c2]), to: &seqState)

        #expect(seqState == flatState)
    }

    @Test(
        ".whenCancelled(primary, fallback) — on primary success, state matches primary-only apply",
        arguments: Array(0..<50)
    )
    @MainActor
    func whenCancelledSuccessEqualsPrimary(seed: Int) {
        var rng = PBTGenerator(seed: seed)
        let engine = NavigationEngine<PBTRoute>()

        var direct = RouteStack<PBTRoute>(path: [.home])
        var wrapped = direct

        // .push always succeeds, so this leg is the "primary success"
        // case. Fallback should not execute.
        let primary = NavigationCommand<PBTRoute>.push(rng.nextRoute())
        let fallback = NavigationCommand<PBTRoute>.push(.profile)

        _ = engine.apply(primary, to: &direct)
        _ = engine.apply(.whenCancelled(primary, fallback: fallback), to: &wrapped)

        #expect(wrapped == direct)
    }

    @Test(
        ".whenCancelled(primary, fallback) — on primary failure, state matches fallback-from-snapshot",
        arguments: Array(0..<50)
    )
    @MainActor
    func whenCancelledFailureEqualsFallback(seed: Int) {
        var rng = PBTGenerator(seed: seed)
        let engine = NavigationEngine<PBTRoute>()

        let snapshot = RouteStack<PBTRoute>(path: [.home])

        // .popCount(-1) always fails; fallback runs on snapshot.
        let failingPrimary = NavigationCommand<PBTRoute>.popCount(-1)
        let fallback = NavigationCommand<PBTRoute>.push(rng.nextRoute())

        var wrapped = snapshot
        _ = engine.apply(.whenCancelled(failingPrimary, fallback: fallback), to: &wrapped)

        var direct = snapshot
        _ = engine.apply(fallback, to: &direct)

        #expect(wrapped == direct)
    }

    @Test(
        ".whenCancelled(primary, fallback) — failed fallback preserves the original snapshot",
        arguments: Array(0..<50)
    )
    @MainActor
    func whenCancelledFallbackFailurePreservesSnapshot(seed: Int) {
        var rng = PBTGenerator(seed: seed)
        let engine = NavigationEngine<PBTRoute>()
        let snapshot = RouteStack<PBTRoute>(path: [.home])
        let inserted = rng.nextRoute()
        let missing: PBTRoute = switch inserted {
        case .settings: .profile
        default: .settings
        }
        let fallback: NavigationCommand<PBTRoute> = .sequence([
            .push(inserted),
            .popTo(missing),
        ])
        var wrapped = snapshot

        let result = engine.apply(
            .whenCancelled(.popCount(-1), fallback: fallback),
            to: &wrapped
        )

        #expect(!result.isSuccess)
        #expect(wrapped == snapshot)
    }
}
