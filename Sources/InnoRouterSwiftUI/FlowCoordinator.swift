import Observation
import SwiftUI

/// Marker protocol for the discrete steps of a `FlowCoordinator`-driven
/// flow.
///
/// Adopters are typically value-typed enums whose case order tracks
/// step progression. The required `index` property defines the
/// progression order without depending on `CaseIterable`'s
/// declaration order.
public protocol FlowStep: Hashable, CaseIterable, Sendable {
    /// Ordinal of the step within the flow. Progression follows
    /// ascending `index` order over `allCases`, so indices may be
    /// non-contiguous (for example `0, 5, 10`) — gaps let flows
    /// insert steps later without renumbering. Indices must be
    /// unique within a flow; duplicate indices leave the relative
    /// order of the duplicates unspecified.
    var index: Int { get }
}

/// A presentation-layer protocol for ordered, multi-step flows
/// (onboarding, sign-up, KYC checklists, etc.).
///
/// `FlowCoordinator` complements `FlowStore` rather than replacing it:
/// `FlowStore` owns the typed navigation/modal stacks behind a flow,
/// while `FlowCoordinator` focuses on the *step* progression — what's
/// the next step, what's already complete, when does the flow finish.
///
/// ## Platform availability
///
/// This protocol and its `FlowCoordinatorView` companion are available
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
/// final class SignUpCoordinator: FlowCoordinator {
///     enum Step: Int, FlowStep { case email, password, profile
///         var index: Int { rawValue }
///     }
///     var currentStep: Step = .email
///     var completedSteps: Set<Step> = []
///     var onComplete: ((Profile) -> Void)?
///     func complete(with profile: Profile) { onComplete?(profile) }
/// }
/// ```
@MainActor
public protocol FlowCoordinator: AnyObject, Observable {
    associatedtype Step: FlowStep
    associatedtype Result

    var currentStep: Step { get set }
    var completedSteps: Set<Step> { get set }
    var onComplete: ((Result) -> Void)? { get set }

    func canProceed(from step: Step) -> Bool
    func complete(with result: Result)
}

public extension FlowCoordinator {
    var totalSteps: Int { Step.allCases.count }

    /// All steps sorted by ascending `index` — the canonical
    /// progression order. Every default implementation below derives
    /// position from this order rather than from raw `index`
    /// arithmetic, so non-contiguous indices progress correctly.
    private var orderedSteps: [Step] {
        Step.allCases.sorted { $0.index < $1.index }
    }

    var progress: Double {
        let steps = orderedSteps
        guard !steps.isEmpty,
              let position = steps.firstIndex(of: currentStep) else { return 0 }
        return Double(position + 1) / Double(steps.count)
    }

    var isAtStart: Bool { orderedSteps.first == currentStep }
    var isAtEnd: Bool { orderedSteps.last == currentStep }

    func next() {
        guard canProceed(from: currentStep) else { return }

        completedSteps.insert(currentStep)

        let steps = orderedSteps
        if let position = steps.firstIndex(of: currentStep),
           position < steps.count - 1 {
            currentStep = steps[position + 1]
        }
    }

    func previous() {
        let steps = orderedSteps
        if let position = steps.firstIndex(of: currentStep),
           position > 0 {
            currentStep = steps[position - 1]
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
        if completedSteps.contains(step) {
            currentStep = step
            return
        }

        let steps = orderedSteps
        guard let targetPosition = steps.firstIndex(of: step),
              let currentPosition = steps.firstIndex(of: currentStep) else { return }

        if targetPosition <= currentPosition {
            currentStep = step
        } else if targetPosition == currentPosition + 1,
                  canProceed(from: currentStep) {
            currentStep = step
        }
    }

    func reset() {
        completedSteps.removeAll()
        if let firstStep = orderedSteps.first {
            currentStep = firstStep
        }
    }

    func canProceed(from step: Step) -> Bool { true }
}

public struct FlowCoordinatorView<C: FlowCoordinator, Content: View>: View {
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
                .animation(.easeInOut, value: coordinator.currentStep.index)
        }
    }
}
