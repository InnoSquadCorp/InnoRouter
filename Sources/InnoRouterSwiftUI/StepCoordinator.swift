import Observation
import SwiftUI

/// A presentation-layer protocol for ordered, multi-step flows
/// (onboarding, sign-up, KYC checklists, etc.).
///
/// `StepCoordinator` complements `FlowStore` rather than replacing it:
/// `FlowStore` owns the typed navigation/modal stacks behind a flow,
/// while `StepCoordinator` focuses on the *step* progression — what's
/// the next step, what's already complete, when does the flow finish.
///
/// ## Platform availability
///
/// This protocol and its `StepCoordinatorView` companion are available
/// on every InnoRouter-supported platform. The view relies on plain
/// `VStack` + `ProgressView` (without `NavigationSplitView`), so it
/// does not require the watchOS fallback that ``NavigationSplitHost``
/// needs.
///
/// ## Conforming
///
/// Conformers are reference types that drive their own `currentStep`
/// state; the protocol is `@MainActor`-isolated because SwiftUI
/// rendering runs on the main actor.
///
/// ```swift
/// @Observable @MainActor
/// final class SignUpCoordinator: StepCoordinator {
///     enum Step: CaseIterable, Hashable, Sendable {
///         case email, password, profile
///     }
///     var currentStep: Step = .email
///     var completedSteps: Set<Step> = []
/// }
/// ```
///
/// Progression follows `Step.allCases`. Synthesized `CaseIterable`
/// conformance uses declaration order; a step type can provide its own
/// `allCases` when the progression order must differ. The collection must
/// be non-empty, contain unique steps, and include any `currentStep` value
/// used by the coordinator. Completion output remains app-owned because the
/// coordinator's transition helpers do not manufacture or consume a result
/// value.
@MainActor
public protocol StepCoordinator: AnyObject, Observable {
    associatedtype Step: CaseIterable & Hashable & Sendable

    var currentStep: Step { get set }
    var completedSteps: Set<Step> { get set }

    /// Returns whether a new forward transition may leave `step`.
    /// Both ``next()`` and a forward ``jump(to:)`` consult this gate.
    func canProceed(from step: Step) -> Bool
}

public extension StepCoordinator {
    var totalSteps: Int { orderedSteps.count }

    /// The canonical progression order. Synthesized `CaseIterable`
    /// conformance preserves declaration order, while a manually
    /// implemented `allCases` can opt into a different order.
    private var orderedSteps: [Step] {
        let steps = Array(Step.allCases)
        precondition(
            !steps.isEmpty,
            "StepCoordinator.Step.allCases must not be empty."
        )
        precondition(
            Set(steps).count == steps.count,
            "StepCoordinator.Step.allCases must contain unique steps."
        )
        return steps
    }

    private func position(of step: Step, in steps: [Step]) -> Int {
        guard let position = steps.firstIndex(of: step) else {
            preconditionFailure(
                "StepCoordinator steps must be present in Step.allCases."
            )
        }
        return position
    }

    var progress: Double {
        let steps = orderedSteps
        let currentPosition = position(of: currentStep, in: steps)
        return Double(currentPosition + 1) / Double(steps.count)
    }

    var isAtStart: Bool {
        let steps = orderedSteps
        return position(of: currentStep, in: steps) == 0
    }

    var isAtEnd: Bool {
        let steps = orderedSteps
        return position(of: currentStep, in: steps) == steps.count - 1
    }

    func next() {
        let steps = orderedSteps
        let currentPosition = position(of: currentStep, in: steps)
        guard canProceed(from: currentStep) else { return }

        completedSteps.insert(currentStep)

        if currentPosition < steps.count - 1 {
            currentStep = steps[currentPosition + 1]
        }
    }

    func previous() {
        let steps = orderedSteps
        let currentPosition = position(of: currentStep, in: steps)
        if currentPosition > 0 {
            currentStep = steps[currentPosition - 1]
        }
    }

    /// Moves directly to `step`.
    ///
    /// Backward jumps and jumps to already-completed steps are always
    /// allowed. A forward jump is allowed only to the immediate next
    /// step in progression order and passes the same
    /// `canProceed(from:)` gate as ``next()``, so `jump(to:)` cannot
    /// skip past a step that `next()` would have blocked.
    func jump(to step: Step) {
        let steps = orderedSteps
        let targetPosition = position(of: step, in: steps)
        let currentPosition = position(of: currentStep, in: steps)

        if completedSteps.contains(step) {
            currentStep = step
            return
        }

        if targetPosition <= currentPosition {
            currentStep = step
        } else if targetPosition == currentPosition + 1,
                  canProceed(from: currentStep) {
            completedSteps.insert(currentStep)
            currentStep = step
        }
    }

    func reset() {
        let steps = orderedSteps
        completedSteps.removeAll()
        currentStep = steps[0]
    }

    func canProceed(from step: Step) -> Bool { true }
}

public struct StepCoordinatorView<C: StepCoordinator, Content: View>: View {
    @Bindable private var coordinator: C
    private let content: (C.Step) -> Content
    private let showProgress: Bool

    public init(
        coordinator: C,
        showProgress: Bool = true,
        @ViewBuilder content: @escaping (C.Step) -> Content
    ) {
        self.coordinator = coordinator
        self.showProgress = showProgress
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showProgress {
                ProgressView(value: coordinator.progress)
                    .padding(.horizontal)
                    .animation(.easeInOut, value: coordinator.progress)
            }

            content(coordinator.currentStep)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut, value: coordinator.currentStep)
        }
    }
}
