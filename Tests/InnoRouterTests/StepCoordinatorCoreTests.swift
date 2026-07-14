// MARK: - StepCoordinatorCoreTests.swift
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

// MARK: - StepCoordinator Tests

@Suite("StepCoordinator Tests")
struct StepCoordinatorTests {

    enum TestStep: CaseIterable, Hashable, Sendable {
        case step1
        case step2
        case step3
    }

    @Observable
    @MainActor
    final class TestStepCoordinator: StepCoordinator {
        typealias Step = TestStep

        var currentStep: TestStep = .step1
        var completedSteps: Set<TestStep> = []

        func canProceed(from step: TestStep) -> Bool {
            true
        }
    }

    @Test("StepCoordinator starts at first step")
    @MainActor
    func testInitialStep() {
        let coordinator = TestStepCoordinator()

        #expect(coordinator.currentStep == .step1)
        #expect(coordinator.isAtStart)
        #expect(!coordinator.isAtEnd)
    }

    @Test("StepCoordinator progresses through steps")
    @MainActor
    func testProgress() {
        let coordinator = TestStepCoordinator()

        coordinator.next()
        #expect(coordinator.currentStep == .step2)
        #expect(coordinator.completedSteps.contains(.step1))

        coordinator.next()
        #expect(coordinator.currentStep == .step3)
        #expect(coordinator.isAtEnd)
    }

    @Test("StepCoordinator can go back")
    @MainActor
    func testPrevious() {
        let coordinator = TestStepCoordinator()
        coordinator.next()
        coordinator.next()

        coordinator.previous()
        #expect(coordinator.currentStep == .step2)
    }

    @Test("StepCoordinator reset clears progress")
    @MainActor
    func testReset() {
        let coordinator = TestStepCoordinator()
        coordinator.next()
        coordinator.next()

        coordinator.reset()

        #expect(coordinator.currentStep == .step1)
        #expect(coordinator.completedSteps.isEmpty)
    }

    @Test("StepCoordinator progress calculation")
    @MainActor
    func testProgressCalculation() {
        let coordinator = TestStepCoordinator()

        #expect(coordinator.progress == 1.0 / 3.0)

        coordinator.next()
        #expect(coordinator.progress == 2.0 / 3.0)

        coordinator.next()
        #expect(coordinator.progress == 1.0)
    }

    // MARK: - Gated progression

    @Observable
    @MainActor
    final class GatedStepCoordinator: StepCoordinator {
        typealias Step = TestStep

        var currentStep: TestStep = .step1
        var completedSteps: Set<TestStep> = []
        var allowedSteps: Set<TestStep> = []

        func canProceed(from step: TestStep) -> Bool {
            allowedSteps.contains(step)
        }
    }

    @Test("jump(to:) forward is gated by canProceed, matching next()")
    @MainActor
    func testJumpForwardRespectsCanProceedGate() {
        let coordinator = GatedStepCoordinator()

        // canProceed(from: .step1) == false: neither next() nor a
        // forward jump may advance.
        coordinator.next()
        #expect(coordinator.currentStep == .step1)
        coordinator.jump(to: .step2)
        #expect(coordinator.currentStep == .step1)
        #expect(!coordinator.completedSteps.contains(.step1))

        // Once the gate opens, the same forward jump succeeds.
        coordinator.allowedSteps = [.step1]
        coordinator.jump(to: .step2)
        #expect(coordinator.currentStep == .step2)
        #expect(coordinator.completedSteps.contains(.step1))
    }

    @Test("jump(to:) cannot skip past the immediate next step")
    @MainActor
    func testJumpCannotSkipSteps() {
        let coordinator = GatedStepCoordinator()
        coordinator.allowedSteps = [.step1, .step2, .step3]

        coordinator.jump(to: .step3)
        #expect(coordinator.currentStep == .step1)
    }

    @Test("jump(to:) to completed or backward steps is always allowed")
    @MainActor
    func testJumpBackwardAndCompleted() {
        let coordinator = GatedStepCoordinator()
        coordinator.allowedSteps = [.step1, .step2]
        coordinator.next()
        coordinator.next()
        #expect(coordinator.currentStep == .step3)

        // Backward jump succeeds even though the gate is now closed.
        coordinator.allowedSteps = []
        coordinator.jump(to: .step1)
        #expect(coordinator.currentStep == .step1)

        // Completed steps stay reachable.
        coordinator.jump(to: .step2)
        #expect(coordinator.currentStep == .step2)
    }
}

// MARK: - Step ordering

@Suite("StepCoordinator ordering Tests")
struct StepCoordinatorOrderingTests {

    /// Raw values intentionally do not describe progression. Synthesized
    /// `allCases` declaration order is the only default ordering contract.
    enum ArbitraryRawValueStep: Int, CaseIterable, Hashable, Sendable {
        case intro = 10
        case detail = 0
        case confirm = 5
    }

    @Observable
    @MainActor
    final class ArbitraryRawValueCoordinator: StepCoordinator {
        typealias Step = ArbitraryRawValueStep

        var currentStep: ArbitraryRawValueStep = .intro
        var completedSteps: Set<ArbitraryRawValueStep> = []
    }

    @Test("next() follows declaration order instead of raw values")
    @MainActor
    func testNextIgnoresRawValues() {
        let coordinator = ArbitraryRawValueCoordinator()

        coordinator.next()
        #expect(coordinator.currentStep == .detail)
        #expect(coordinator.completedSteps.contains(.intro))

        coordinator.next()
        #expect(coordinator.currentStep == .confirm)
        #expect(coordinator.isAtEnd)
    }

    @Test("previous() follows declaration order instead of raw values")
    @MainActor
    func testPreviousIgnoresRawValues() {
        let coordinator = ArbitraryRawValueCoordinator()
        coordinator.next()
        coordinator.next()

        coordinator.previous()
        #expect(coordinator.currentStep == .detail)

        coordinator.previous()
        #expect(coordinator.currentStep == .intro)
        #expect(coordinator.isAtStart)
    }

    @Test("progress and isAtEnd use declaration position, not raw value")
    @MainActor
    func testProgressUsesOrderedPosition() {
        let coordinator = ArbitraryRawValueCoordinator()

        #expect(coordinator.progress == 1.0 / 3.0)
        #expect(!coordinator.isAtEnd)

        coordinator.next()
        #expect(coordinator.progress == 2.0 / 3.0)

        coordinator.next()
        #expect(coordinator.progress == 1.0)
        #expect(coordinator.isAtEnd)
    }

    @Test("jump(to:) uses declaration order")
    @MainActor
    func testJumpUsesDeclarationOrder() {
        let coordinator = ArbitraryRawValueCoordinator()

        // .detail is next even though its raw value is lower.
        coordinator.jump(to: .detail)
        #expect(coordinator.currentStep == .detail)

        // .confirm would skip nothing now, but from .intro it would.
        coordinator.jump(to: .intro)
        coordinator.jump(to: .confirm)
        #expect(coordinator.currentStep == .intro)
    }

    enum CustomOrderStep: CaseIterable, Hashable, Sendable {
        case intro
        case detail
        case confirm

        static let allCases: [Self] = [.detail, .intro, .confirm]
    }

    @Observable
    @MainActor
    final class CustomOrderCoordinator: StepCoordinator {
        typealias Step = CustomOrderStep

        var currentStep: CustomOrderStep = .intro
        var completedSteps: Set<CustomOrderStep> = []
    }

    @Test("manual allCases defines custom progression and reset order")
    @MainActor
    func testCustomAllCasesOrder() {
        let coordinator = CustomOrderCoordinator()

        coordinator.reset()
        #expect(coordinator.currentStep == .detail)
        #expect(coordinator.isAtStart)

        coordinator.next()
        #expect(coordinator.currentStep == .intro)
        #expect(coordinator.progress == 2.0 / 3.0)
    }
}
