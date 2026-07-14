// MARK: - FlowCoordinatorCoreTests.swift
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

// MARK: - FlowCoordinator Tests

@Suite("FlowCoordinator Tests")
struct FlowCoordinatorTests {

    enum TestStep: Int, FlowStep, CaseIterable {
        case step1 = 0
        case step2 = 1
        case step3 = 2

        var index: Int { rawValue }
    }

    @Observable
    @MainActor
    final class TestFlowCoordinator: FlowCoordinator {
        typealias Step = TestStep
        typealias Result = String

        var currentStep: TestStep = .step1
        var completedSteps: Set<TestStep> = []
        var onComplete: ((String) -> Void)?

        func canProceed(from step: TestStep) -> Bool {
            true
        }

        func complete(with result: String) {
            onComplete?(result)
        }
    }

    @Test("FlowCoordinator starts at first step")
    @MainActor
    func testInitialStep() {
        let coordinator = TestFlowCoordinator()

        #expect(coordinator.currentStep == .step1)
        #expect(coordinator.isAtStart)
        #expect(!coordinator.isAtEnd)
    }

    @Test("FlowCoordinator progresses through steps")
    @MainActor
    func testProgress() {
        let coordinator = TestFlowCoordinator()

        coordinator.next()
        #expect(coordinator.currentStep == .step2)
        #expect(coordinator.completedSteps.contains(.step1))

        coordinator.next()
        #expect(coordinator.currentStep == .step3)
        #expect(coordinator.isAtEnd)
    }

    @Test("FlowCoordinator can go back")
    @MainActor
    func testPrevious() {
        let coordinator = TestFlowCoordinator()
        coordinator.next()
        coordinator.next()

        coordinator.previous()
        #expect(coordinator.currentStep == .step2)
    }

    @Test("FlowCoordinator reset clears progress")
    @MainActor
    func testReset() {
        let coordinator = TestFlowCoordinator()
        coordinator.next()
        coordinator.next()

        coordinator.reset()

        #expect(coordinator.currentStep == .step1)
        #expect(coordinator.completedSteps.isEmpty)
    }

    @Test("FlowCoordinator progress calculation")
    @MainActor
    func testProgressCalculation() {
        let coordinator = TestFlowCoordinator()

        #expect(coordinator.progress == 1.0 / 3.0)

        coordinator.next()
        #expect(coordinator.progress == 2.0 / 3.0)

        coordinator.next()
        #expect(coordinator.progress == 1.0)
    }

    // MARK: - Gated progression

    @Observable
    @MainActor
    final class GatedFlowCoordinator: FlowCoordinator {
        typealias Step = TestStep
        typealias Result = String

        var currentStep: TestStep = .step1
        var completedSteps: Set<TestStep> = []
        var onComplete: ((String) -> Void)?
        var allowedSteps: Set<TestStep> = []

        func canProceed(from step: TestStep) -> Bool {
            allowedSteps.contains(step)
        }

        func complete(with result: String) {
            onComplete?(result)
        }
    }

    @Test("jump(to:) forward is gated by canProceed, matching next()")
    @MainActor
    func testJumpForwardRespectsCanProceedGate() {
        let coordinator = GatedFlowCoordinator()

        // canProceed(from: .step1) == false: neither next() nor a
        // forward jump may advance.
        coordinator.next()
        #expect(coordinator.currentStep == .step1)
        coordinator.jump(to: .step2)
        #expect(coordinator.currentStep == .step1)

        // Once the gate opens, the same forward jump succeeds.
        coordinator.allowedSteps = [.step1]
        coordinator.jump(to: .step2)
        #expect(coordinator.currentStep == .step2)
    }

    @Test("jump(to:) cannot skip past the immediate next step")
    @MainActor
    func testJumpCannotSkipSteps() {
        let coordinator = GatedFlowCoordinator()
        coordinator.allowedSteps = [.step1, .step2, .step3]

        coordinator.jump(to: .step3)
        #expect(coordinator.currentStep == .step1)
    }

    @Test("jump(to:) to completed or backward steps is always allowed")
    @MainActor
    func testJumpBackwardAndCompleted() {
        let coordinator = GatedFlowCoordinator()
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

// MARK: - Non-contiguous FlowStep indices

@Suite("FlowCoordinator gapped index Tests")
struct FlowCoordinatorGappedIndexTests {

    /// Indices intentionally leave gaps (0, 5, 10) — the documented
    /// "insert steps later without renumbering" shape.
    enum GappedStep: Int, FlowStep, CaseIterable {
        case intro = 0
        case detail = 5
        case confirm = 10

        var index: Int { rawValue }
    }

    @Observable
    @MainActor
    final class GappedFlowCoordinator: FlowCoordinator {
        typealias Step = GappedStep
        typealias Result = String

        var currentStep: GappedStep = .intro
        var completedSteps: Set<GappedStep> = []
        var onComplete: ((String) -> Void)?

        func complete(with result: String) {
            onComplete?(result)
        }
    }

    @Test("next() advances across index gaps")
    @MainActor
    func testNextAdvancesAcrossGaps() {
        let coordinator = GappedFlowCoordinator()

        coordinator.next()
        #expect(coordinator.currentStep == .detail)
        #expect(coordinator.completedSteps.contains(.intro))

        coordinator.next()
        #expect(coordinator.currentStep == .confirm)
        #expect(coordinator.isAtEnd)
    }

    @Test("previous() rewinds across index gaps")
    @MainActor
    func testPreviousRewindsAcrossGaps() {
        let coordinator = GappedFlowCoordinator()
        coordinator.next()
        coordinator.next()

        coordinator.previous()
        #expect(coordinator.currentStep == .detail)

        coordinator.previous()
        #expect(coordinator.currentStep == .intro)
        #expect(coordinator.isAtStart)
    }

    @Test("progress and isAtEnd use progression position, not raw index")
    @MainActor
    func testProgressUsesOrderedPosition() {
        let coordinator = GappedFlowCoordinator()

        #expect(coordinator.progress == 1.0 / 3.0)
        #expect(!coordinator.isAtEnd)

        coordinator.next()
        #expect(coordinator.progress == 2.0 / 3.0)

        coordinator.next()
        #expect(coordinator.progress == 1.0)
        #expect(coordinator.isAtEnd)
    }

    @Test("jump(to:) forward across a gap targets the next ordered step")
    @MainActor
    func testJumpAcrossGap() {
        let coordinator = GappedFlowCoordinator()

        // .detail is the immediate next ordered step despite index 5.
        coordinator.jump(to: .detail)
        #expect(coordinator.currentStep == .detail)

        // .confirm would skip nothing now, but from .intro it would.
        coordinator.jump(to: .intro)
        coordinator.jump(to: .confirm)
        #expect(coordinator.currentStep == .intro)
    }
}
