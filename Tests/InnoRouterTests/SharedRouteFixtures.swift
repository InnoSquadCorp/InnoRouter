// MARK: - SharedRouteFixtures.swift
// InnoRouter Tests
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import Observation
import OSLog
import Synchronization
import SwiftUI
import InnoRouter
import InnoRouterEffects
@testable import InnoRouterSwiftUI

// MARK: - Test Route

enum TestRoute: Route {
    case home
    case detail(id: String)
    case settings
    case profile(userId: String, tab: Int)
}

enum TestModalRoute: Route {
    case profile
    case onboarding
}

enum TestBoundModalRoute: Route {
    case profile(id: String)
    case onboarding
}

enum TestValidationError: Error, Equatable {
    case rejected
}

// MARK: - Property Test Helpers

struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        (next() & 1) == 0
    }
}

func validatedStack<R: Route>(_ path: [R]) throws -> RouteStack<R> {
    try RouteStack(validating: path)
}

let allTestRoutes: [TestRoute] = [
    .home,
    .settings,
    .detail(id: "123"),
    .detail(id: "456"),
    .profile(userId: "u1", tab: 0),
    .profile(userId: "u2", tab: 1)
]

func randomRoute(rng: inout SeededGenerator) -> TestRoute {
    allTestRoutes[rng.nextInt(upperBound: allTestRoutes.count)]
}

func randomRouteList(rng: inout SeededGenerator) -> [TestRoute] {
    let count = rng.nextInt(upperBound: 4)
    return (0..<count).map { _ in randomRoute(rng: &rng) }
}

func randomNavigationCommand(
    rng: inout SeededGenerator,
    currentPath: [TestRoute],
    depth: Int
) -> NavigationCommand<TestRoute> {
    let allowSequence = depth < 2
    let upperBound = allowSequence ? 8 : 7

    switch rng.nextInt(upperBound: upperBound) {
    case 0:
        return .push(randomRoute(rng: &rng))
    case 1:
        return .pushAll(randomRouteList(rng: &rng))
    case 2:
        return .pop
    case 3:
        let requested = rng.nextInt(upperBound: 4)
        return .popCount(requested)
    case 4:
        return .popToRoot
    case 5:
        if !currentPath.isEmpty, rng.nextBool() {
            return .popTo(currentPath[rng.nextInt(upperBound: currentPath.count)])
        }
        return .popTo(randomRoute(rng: &rng))
    case 6:
        return .replace(randomRouteList(rng: &rng))
    default:
        let count = rng.nextInt(upperBound: 3) + 1
        let commands = (0..<count).map { _ in
            randomNavigationCommand(rng: &rng, currentPath: currentPath, depth: depth + 1)
        }
        return .sequence(commands)
    }
}

func previewReferenceResult(
    _ command: NavigationCommand<TestRoute>,
    path: [TestRoute]
) -> NavigationResult<TestRoute> {
    var copy = path
    return applyReference(command, to: &copy)
}

func applyReference(
    _ command: NavigationCommand<TestRoute>,
    to path: inout [TestRoute]
) -> NavigationResult<TestRoute> {
    switch command {
    case .push(let route):
        path.append(route)
        return .success

    case .pushAll(let routes):
        path.append(contentsOf: routes)
        return .success

    case .pop:
        guard !path.isEmpty else { return .emptyStack }
        _ = path.removeLast()
        return .success

    case .popCount(let count):
        guard count > 0 else { return .invalidPopCount(count) }
        guard count <= path.count else {
            return .insufficientStackDepth(requested: count, available: path.count)
        }
        path.removeLast(count)
        return .success

    case .popToRoot:
        path.removeAll()
        return .success

    case .popTo(let route):
        guard let index = path.lastIndex(of: route) else { return .routeNotFound(route) }
        path = Array(path.prefix(through: index))
        return .success

    case .replace(let routes):
        path = routes
        return .success

    case .sequence(let commands):
        let results = commands.map { applyReference($0, to: &path) }
        return .multiple(results)

    case .whenCancelled(let primary, let fallback):
        let snapshot = path
        var primaryPath = snapshot
        let primaryResult = applyReference(primary, to: &primaryPath)
        if primaryResult.isSuccess {
            path = primaryPath
            return primaryResult
        }

        var fallbackPath = snapshot
        let fallbackResult = applyReference(fallback, to: &fallbackPath)
        path = fallbackResult.isSuccess ? fallbackPath : snapshot
        return fallbackResult
    }
}
