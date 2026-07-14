// MARK: - TypedCaseBindingTests.swift
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

// MARK: - Typed Case Binding Tests

private let testRouteDetailCase = CasePath<TestRoute, String>(
    embed: { TestRoute.detail(id: $0) },
    extract: { route in
        if case .detail(let id) = route { return id }
        return nil
    }
)

private let testModalProfileCase = CasePath<TestModalRoute, Void>(
    embed: { _ in TestModalRoute.profile },
    extract: { route in
        if case .profile = route { return () }
        return nil
    }
)

private let testBoundModalProfileCase = CasePath<TestBoundModalRoute, String>(
    embed: { TestBoundModalRoute.profile(id: $0) },
    extract: { route in
        if case .profile(let id) = route { return id }
        return nil
    }
)

@Suite("Typed Case Binding Tests")
struct TypedCaseBindingTests {
    @Test("NavigationStore binding(case:) extracts when case matches top")
    @MainActor
    func testNavigationBindingExtracts() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "42")]
        )

        let binding = store.binding(case: testRouteDetailCase)

        #expect(binding.wrappedValue == "42")
    }

    @Test("NavigationStore binding(case:) returns nil when case does not match")
    @MainActor
    func testNavigationBindingReturnsNilForMismatch() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .settings])

        let binding = store.binding(case: testRouteDetailCase)

        #expect(binding.wrappedValue == nil)
    }

    @Test("NavigationStore binding(case:) push routes through middleware")
    @MainActor
    func testNavigationBindingPushUsesCommandPipeline() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home])
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testRouteDetailCase).wrappedValue = "99"

        #expect(seenCommands == [.push(.detail(id: "99"))])
        #expect(store.state.path == [.home, .detail(id: "99")])
    }

    @Test("NavigationStore binding(case:) rewrites matching top instead of pushing duplicate")
    @MainActor
    func testNavigationBindingRewritesMatchingTop() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "42")]
        )
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testRouteDetailCase).wrappedValue = "99"

        #expect(seenCommands == [.replace([.home, .detail(id: "99")])])
        #expect(store.state.path == [.home, .detail(id: "99")])
    }

    @Test("NavigationStore binding(case:) same value is a no-op")
    @MainActor
    func testNavigationBindingSameValueIsNoOp() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "42")]
        )
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testRouteDetailCase).wrappedValue = "42"

        #expect(seenCommands.isEmpty)
        #expect(store.state.path == [.home, .detail(id: "42")])
    }

    @Test("NavigationStore binding(case:) nil pops only when case matches top")
    @MainActor
    func testNavigationBindingNilPopsWhenCaseMatches() throws {
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home, .detail(id: "42")]
        )
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testRouteDetailCase).wrappedValue = nil

        #expect(seenCommands == [.pop])
        #expect(store.state.path == [.home])
    }

    @Test("NavigationStore binding(case:) nil is a no-op when case differs")
    @MainActor
    func testNavigationBindingNilNoOpForMismatch() throws {
        let store = try NavigationStore<TestRoute>(initialPath: [.home, .settings])
        var seenCommands: [NavigationCommand<TestRoute>] = []

        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testRouteDetailCase).wrappedValue = nil

        #expect(seenCommands.isEmpty)
        #expect(store.state.path == [.home, .settings])
    }

    @Test("ModalStore binding(case:) extracts when current presentation matches")
    @MainActor
    func testModalBindingExtracts() {
        let store = ModalStore<TestModalRoute>()
        store.present(.profile, style: .sheet)

        let binding = store.binding(case: testModalProfileCase)

        #expect(binding.wrappedValue != nil)
    }

    @Test("ModalStore binding(case:style:) returns nil when style does not match")
    @MainActor
    func testModalBindingReturnsNilForStyleMismatch() {
        let store = ModalStore<TestModalRoute>()
        store.present(.profile, style: .fullScreenCover)

        let binding = store.binding(case: testModalProfileCase, style: .sheet)

        #expect(binding.wrappedValue == nil)
    }

    @Test("ModalStore binding(case:) present routes through command pipeline")
    @MainActor
    func testModalBindingPresentEmitsCommand() {
        let store = ModalStore<TestModalRoute>()
        var seenCommands: [ModalCommand<TestModalRoute>] = []

        store.addMiddleware(
            AnyModalMiddleware(
                willExecute: { command, _, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testModalProfileCase, style: .sheet).wrappedValue = ()

        #expect(seenCommands.count == 1)
        #expect(store.currentPresentation?.route == .profile)
    }

    @Test("ModalStore binding(case:style:) updates matching presentation without queueing")
    @MainActor
    func testModalBindingMatchingUpdateUsesReplaceCurrent() {
        let store = ModalStore<TestBoundModalRoute>()
        store.present(.profile(id: "42"), style: .sheet)
        let originalID = store.currentPresentation?.id
        var seenCommands: [ModalCommand<TestBoundModalRoute>] = []

        store.addMiddleware(
            AnyModalMiddleware(
                willExecute: { command, _, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testBoundModalProfileCase, style: .sheet).wrappedValue = "99"

        let expectedPresentation = ModalPresentation(
            id: originalID!,
            route: TestBoundModalRoute.profile(id: "99"),
            style: .sheet
        )
        #expect(seenCommands == [.replaceCurrent(expectedPresentation)])
        #expect(store.currentPresentation == expectedPresentation)
        #expect(store.queuedPresentations.isEmpty)
    }

    @Test("ModalStore binding(case:style:) same value is a no-op")
    @MainActor
    func testModalBindingSameValueIsNoOp() {
        let store = ModalStore<TestBoundModalRoute>()
        store.present(.profile(id: "42"), style: .sheet)
        let originalPresentation = store.currentPresentation
        var seenCommands: [ModalCommand<TestBoundModalRoute>] = []

        store.addMiddleware(
            AnyModalMiddleware(
                willExecute: { command, _, _ in
                    seenCommands.append(command)
                    return .proceed(command)
                }
            )
        )

        store.binding(case: testBoundModalProfileCase, style: .sheet).wrappedValue = "42"

        #expect(seenCommands.isEmpty)
        #expect(store.currentPresentation == originalPresentation)
        #expect(store.queuedPresentations.isEmpty)
    }

    @Test("ModalStore binding(case:) nil dismisses when case matches current")
    @MainActor
    func testModalBindingNilDismissesWhenMatching() {
        let store = ModalStore<TestModalRoute>()
        store.present(.profile, style: .sheet)

        store.binding(case: testModalProfileCase).wrappedValue = nil

        #expect(store.currentPresentation == nil)
    }

    @Test("ModalStore binding(case:style:) nil uses systemDismiss reason")
    @MainActor
    func testModalBindingNilUsesSystemDismissReason() {
        let dismissed = Mutex<[(ModalPresentation<TestModalRoute>, ModalDismissalReason)]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .dismissed(let presentation, let reason) = event else { return }
                    dismissed.withLock { $0.append((presentation, reason)) }
                }
            )
        )
        store.present(.profile, style: .sheet)

        store.binding(case: testModalProfileCase, style: .sheet).wrappedValue = nil

        #expect(dismissed.withLock(\.count) == 1)
        #expect(dismissed.withLock(\.first)?.0.route == .profile)
        #expect(dismissed.withLock(\.first)?.1 == .systemDismiss)
    }

    @Test("ModalStore binding(case:style:) nil ignores mismatched style")
    @MainActor
    func testModalBindingNilIgnoresStyleMismatch() {
        let store = ModalStore<TestModalRoute>()
        store.present(.profile, style: .fullScreenCover)

        store.binding(case: testModalProfileCase, style: .sheet).wrappedValue = nil

        #expect(store.currentPresentation?.route == .profile)
        #expect(store.currentPresentation?.style == .fullScreenCover)
    }
}
