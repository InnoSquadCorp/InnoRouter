// MARK: - PropertyTestSupport.swift
// InnoRouterTests - shared support for FlowStore / deep-link property tests
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI
import InnoRouterDeepLink
import InnoRouterEffects

enum PropertyRoute: String, CaseIterable, Route {
    case home
    case detail
    case settings
    case profile
    case secure
    case legal
    case promo
}

struct PropertyPBTGenerator {
    private var state: UInt64

    init(seed: Int) {
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : UInt64(bitPattern: Int64(seed))
    }

    mutating func nextInt(upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % max(upperBound, 1)
    }

    mutating func nextBool() -> Bool {
        nextInt(upperBound: 2) == 0
    }

    mutating func chance(_ numerator: Int, outOf denominator: Int) -> Bool {
        nextInt(upperBound: denominator) < numerator
    }

    mutating func nextRoute() -> PropertyRoute {
        PropertyRoute.allCases[nextInt(upperBound: PropertyRoute.allCases.count)]
    }

    mutating func nextModalStyle() -> ModalPresentationStyle {
        nextBool() ? .sheet : .fullScreenCover
    }

    mutating func nextRoutes(maxCount: Int = 4) -> [PropertyRoute] {
        let count = nextInt(upperBound: maxCount + 1)
        return (0..<count).map { _ in nextRoute() }
    }

    mutating func nextLeafNavigationCommand() -> NavigationCommand<PropertyRoute> {
        switch nextInt(upperBound: 100) {
        case 0..<26:
            return .push(nextRoute())
        case 26..<38:
            return .replace(nextRoutes(maxCount: 3))
        case 38..<48:
            return .pushAll(nextRoutes(maxCount: 3))
        case 48..<60:
            return .pop
        case 60..<72:
            return .popTo(nextRoute())
        case 72..<82:
            return .popToRoot
        default:
            return .popCount(nextInt(upperBound: 5))
        }
    }

    mutating func nextCompositeNavigationCommand(maxDepth: Int = 2) -> NavigationCommand<PropertyRoute> {
        guard maxDepth > 0 else { return nextLeafNavigationCommand() }

        switch nextInt(upperBound: 100) {
        case 0..<58:
            return nextLeafNavigationCommand()
        case 58..<80:
            let count = max(2, nextInt(upperBound: 4))
            let commands = (0..<count).map { _ in
                nextCompositeNavigationCommand(maxDepth: maxDepth - 1)
            }
            return .sequence(commands)
        default:
            let primary = nextCompositeNavigationCommand(maxDepth: maxDepth - 1)
            let fallback = nextCompositeNavigationCommand(maxDepth: maxDepth - 1)
            return .whenCancelled(primary, fallback: fallback)
        }
    }

    mutating func nextTransactionCommands() -> [NavigationCommand<PropertyRoute>] {
        let count = max(1, nextInt(upperBound: 4))
        return (0..<count).map { _ in nextLeafNavigationCommand() }
    }

    mutating func nextFlowSteps() -> [RouteStep<PropertyRoute>] {
        if chance(1, outOf: 5) {
            return nextInvalidFlowSteps()
        }
        return nextValidFlowSteps()
    }

    mutating func nextHandledURLCase() -> PropertyURLCase {
        let handled: [PropertyURLCase] = [
            .home,
            .homeDetail,
            .settingsProfile,
            .modalLegal,
            .homeModalLegal,
            .secure,
            .homeSecure
        ]
        return handled[nextInt(upperBound: handled.count)]
    }

    mutating func nextURLCase() -> PropertyURLCase {
        PropertyURLCase.allCases[nextInt(upperBound: PropertyURLCase.allCases.count)]
    }

    mutating func nextReplayAction() -> PropertyReplayAction {
        switch nextInt(upperBound: 100) {
        case 0..<48:
            return .handle(nextURLCase())
        case 48..<62:
            return .setAuthenticated(nextBool())
        case 62..<74:
            return .resumePending
        case 74..<86:
            return .resumePendingIfAllowed(nextBool())
        default:
            return .clearPending
        }
    }

    private mutating func nextValidFlowSteps() -> [RouteStep<PropertyRoute>] {
        var steps = nextRoutes(maxCount: 3).map(RouteStep.push)
        if chance(1, outOf: 3) {
            let route = nextRoute()
            let modalStep: RouteStep<PropertyRoute> = nextBool() ? .sheet(route) : .cover(route)
            steps.append(modalStep)
        }
        return steps
    }

    private mutating func nextInvalidFlowSteps() -> [RouteStep<PropertyRoute>] {
        switch nextInt(upperBound: 3) {
        case 0:
            return [.sheet(nextRoute()), .push(nextRoute())]
        case 1:
            return [.push(nextRoute()), .sheet(nextRoute()), .cover(nextRoute())]
        default:
            return [.cover(nextRoute()), .sheet(nextRoute())]
        }
    }
}

@MainActor
func randomFlowIntent(
    rng: inout PropertyPBTGenerator
) -> FlowIntent<PropertyRoute> {
    let route = rng.nextRoute()
    switch rng.nextInt(upperBound: 100) {
    case 0..<18:
        return .push(route)
    case 18..<32:
        return .presentSheet(route)
    case 32..<42:
        return .presentCover(route)
    case 42..<54:
        return .pop
    case 54..<64:
        return .dismiss
    case 64..<76:
        return .reset(rng.nextFlowSteps())
    case 76..<84:
        return .replaceStack(rng.nextRoutes(maxCount: 3))
    case 84..<90:
        return .backOrPush(route)
    case 90..<95:
        return .pushUniqueRoot(route)
    case 95..<98:
        return .backOrPushDismissingModal(route)
    default:
        return .pushUniqueRootDismissingModal(route)
    }
}

struct ModelModalState: Equatable {
    let route: PropertyRoute
    let style: ModalPresentationStyle

    var step: RouteStep<PropertyRoute> {
        switch style {
        case .sheet:
            return .sheet(route)
        case .fullScreenCover:
            return .cover(route)
        }
    }
}

protocol PropertyFlowMiddlewareModeling {
    func navigationDecision(
        for command: NavigationCommand<PropertyRoute>,
        state: RouteStack<PropertyRoute>
    ) -> PropertyNavigationDecision

    func modalDecision(
        for command: ModalCommand<PropertyRoute>,
        currentPresentation: ModelModalState?,
        queuedPresentations: [ModelModalState]
    ) -> PropertyModalDecision
}

struct FlowModelState: Equatable {
    var navigationPath: [PropertyRoute] = []
    var currentModal: ModelModalState?
    var queuedModals: [ModelModalState] = []
    var lastRejection: FlowRejectionReason?

    init() {}

    init(plan: FlowPlan<PropertyRoute>) {
        let modalStep = plan.steps.last.flatMap { $0.isModal ? $0 : nil }
        self.navigationPath = plan.steps
            .filter { !$0.isModal }
            .map(\.route)
        self.currentModal = modalStep.map {
            ModelModalState(route: $0.route, style: $0.modalStyle ?? .sheet)
        }
        self.queuedModals = []
        self.lastRejection = nil
    }

    var path: [RouteStep<PropertyRoute>] {
        var steps = navigationPath.map(RouteStep.push)
        if let currentModal {
            steps.append(currentModal.step)
        }
        return steps
    }

    mutating func apply(
        _ intent: FlowIntent<PropertyRoute>,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)? = nil
    ) -> FlowStepExpectation {
        lastRejection = nil
        switch intent {
        case .push(let route):
            return applyPush(route, middlewarePolicy: middlewarePolicy)
        case .presentSheet(let route):
            return applyModalPresent(
                ModelModalState(route: route, style: .sheet),
                middlewarePolicy: middlewarePolicy
            )
        case .presentCover(let route):
            return applyModalPresent(
                ModelModalState(route: route, style: .fullScreenCover),
                middlewarePolicy: middlewarePolicy
            )
        case .pop:
            return applyPop(middlewarePolicy: middlewarePolicy)
        case .dismiss:
            return applyDismiss(middlewarePolicy: middlewarePolicy)
        case .reset(let steps):
            return applyReset(steps, middlewarePolicy: middlewarePolicy)
        case .replaceStack(let routes):
            return applyReset(routes.map(RouteStep.push), middlewarePolicy: middlewarePolicy)
        case .backOrPush(let route):
            return applyBackOrPush(route, middlewarePolicy: middlewarePolicy)
        case .pushUniqueRoot(let route):
            return applyPushUniqueRoot(route, middlewarePolicy: middlewarePolicy)
        case .backOrPushDismissingModal(let route):
            return applyDismissingModal(
                middlewarePolicy: middlewarePolicy,
                next: { state in
                    state.applyBackOrPush(route, middlewarePolicy: middlewarePolicy)
                }
            )
        case .pushUniqueRootDismissingModal(let route):
            return applyDismissingModal(
                middlewarePolicy: middlewarePolicy,
                next: { state in
                    state.applyPushUniqueRoot(route, middlewarePolicy: middlewarePolicy)
                }
            )
        }
    }

    private mutating func applyPush(
        _ route: PropertyRoute,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        guard currentModal == nil else {
            return reject(.pushBlockedByModalTail)
        }
        switch navigationDecision(for: .push(route), middlewarePolicy: middlewarePolicy) {
        case .cancel(let debugName, _):
            return reject(.middlewareRejected(debugName: debugName))
        case .proceed(let command):
            let changed = applyNavigationCommand(command)
            return FlowStepExpectation(
                outcome: changed ? .pathChangedLast : .none,
                navigationChanged: changed
            )
        }
    }

    private mutating func applyModalPresent(
        _ modal: ModelModalState,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        let command = ModalCommand<PropertyRoute>.present(
            ModalPresentation(route: modal.route, style: modal.style)
        )
        switch modalDecision(for: command, middlewarePolicy: middlewarePolicy) {
        case .cancel(let debugName, _):
            return reject(.middlewareRejected(debugName: debugName))
        case .proceed(let effectiveCommand):
            let delta = applyModalCommand(effectiveCommand)
            return FlowStepExpectation(
                outcome: delta.pathChanged ? .pathChangedLast : .none,
                modalPresented: delta.presented,
                modalDismissed: delta.dismissed,
                modalQueueChanged: delta.queueChanged
            )
        }
    }

    private mutating func applyPop(
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        guard currentModal == nil, !navigationPath.isEmpty else {
            return FlowStepExpectation(outcome: .none)
        }
        switch navigationDecision(for: .pop, middlewarePolicy: middlewarePolicy) {
        case .cancel(let debugName, _):
            return reject(.middlewareRejected(debugName: debugName))
        case .proceed(let command):
            let changed = applyNavigationCommand(command)
            return FlowStepExpectation(
                outcome: changed ? .pathChangedLast : .none,
                navigationChanged: changed
            )
        }
    }

    private mutating func applyDismiss(
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        guard currentModal != nil else {
            return FlowStepExpectation(outcome: .none)
        }
        return applyModalDismissCommand(
            .dismissCurrent(reason: .dismiss),
            middlewarePolicy: middlewarePolicy
        )
    }

    private mutating func applyBackOrPush(
        _ route: PropertyRoute,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        guard currentModal == nil else {
            return reject(.pushBlockedByModalTail)
        }

        if navigationPath.contains(route) {
            switch navigationDecision(for: .popTo(route), middlewarePolicy: middlewarePolicy) {
            case .cancel(let debugName, _):
                return reject(.middlewareRejected(debugName: debugName))
            case .proceed(let command):
                let changed = applyNavigationCommand(command)
                return FlowStepExpectation(
                    outcome: changed ? .pathChangedLast : .none,
                    navigationChanged: changed
                )
            }
        }

        return applyPush(route, middlewarePolicy: middlewarePolicy)
    }

    private mutating func applyPushUniqueRoot(
        _ route: PropertyRoute,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        guard !navigationPath.contains(route) else {
            return FlowStepExpectation(outcome: .none)
        }
        return applyPush(route, middlewarePolicy: middlewarePolicy)
    }

    private mutating func applyDismissingModal(
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?,
        next: (inout FlowModelState) -> FlowStepExpectation
    ) -> FlowStepExpectation {
        guard currentModal != nil else {
            return next(&self)
        }

        let dismissExpectation = applyModalDismissCommand(
            .dismissCurrent(reason: .dismiss),
            middlewarePolicy: middlewarePolicy
        )

        switch dismissExpectation.outcome {
        case .rejectedOnly(_):
            return dismissExpectation
        case .pathChangedThenRejected(_):
            return dismissExpectation
        case .none, .pathChangedLast:
            break
        }

        if currentModal != nil {
            lastRejection = .pushBlockedByModalTail
            var expectation = dismissExpectation
            expectation.outcome = dismissExpectation.outcome == .pathChangedLast
                ? .pathChangedThenRejected(.pushBlockedByModalTail)
                : .rejectedOnly(.pushBlockedByModalTail)
            return expectation
        }

        let innerExpectation = next(&self)
        return dismissExpectation.merged(with: innerExpectation)
    }

    private mutating func applyReset(
        _ steps: [RouteStep<PropertyRoute>],
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        guard Self.isValidPath(steps) else {
            return reject(.invalidResetPath)
        }

        let oldState = self
        let oldPath = path
        let (pushRoutes, modalTail) = Self.decompose(steps)
        var shadow = self

        switch shadow.navigationDecision(
            for: .replace(pushRoutes),
            middlewarePolicy: middlewarePolicy
        ) {
        case .cancel(let debugName, _):
            return reject(.middlewareRejected(debugName: debugName))
        case .proceed(let command):
            let navigationChanged = shadow.applyNavigationCommand(command)
            let modalResetResult = shadow.previewModalReset(
                to: modalTail,
                middlewarePolicy: middlewarePolicy
            )
            switch modalResetResult {
            case .rejected(let reason):
                self = oldState
                return reject(reason)
            case .applied(let delta):
                self = shadow
                return FlowStepExpectation(
                    outcome: path != oldPath ? .pathChangedLast : .none,
                    navigationChanged: navigationChanged,
                    modalPresented: delta.presented,
                    modalDismissed: delta.dismissed,
                    modalQueueChanged: delta.queueChanged
                )
            }
        }
    }

    private mutating func applyModalDismissCommand(
        _ command: ModalCommand<PropertyRoute>,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> FlowStepExpectation {
        switch modalDecision(for: command, middlewarePolicy: middlewarePolicy) {
        case .cancel(let debugName, _):
            return reject(.middlewareRejected(debugName: debugName))
        case .proceed(let effectiveCommand):
            let delta = applyModalCommand(effectiveCommand)
            return FlowStepExpectation(
                outcome: delta.pathChanged ? .pathChangedLast : .none,
                modalPresented: delta.presented,
                modalDismissed: delta.dismissed,
                modalQueueChanged: delta.queueChanged
            )
        }
    }

    private mutating func previewModalReset(
        to modalTail: RouteStep<PropertyRoute>?,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> ModalResetPreview {
        let targetModal = modalTail.map {
            ModelModalState(route: $0.route, style: $0.modalStyle ?? .sheet)
        }

        if currentModal == targetModal, queuedModals.isEmpty {
            return .applied(ModalMutationDelta())
        }

        var delta = ModalMutationDelta()

        if currentModal != nil || !queuedModals.isEmpty {
            switch modalDecision(for: .dismissAll, middlewarePolicy: middlewarePolicy) {
            case .cancel(let debugName, _):
                return .rejected(.middlewareRejected(debugName: debugName))
            case .proceed(let command):
                delta.formUnion(applyModalCommand(command))
            }
        }

        if let targetModal {
            let command = ModalCommand<PropertyRoute>.present(
                ModalPresentation(route: targetModal.route, style: targetModal.style)
            )
            switch modalDecision(for: command, middlewarePolicy: middlewarePolicy) {
            case .cancel(let debugName, _):
                return .rejected(.middlewareRejected(debugName: debugName))
            case .proceed(let effectiveCommand):
                delta.formUnion(applyModalCommand(effectiveCommand))
            }
        }

        return .applied(delta)
    }

    private mutating func applyNavigationCommand(
        _ command: NavigationCommand<PropertyRoute>
    ) -> Bool {
        let before = navigationPath
        switch command {
        case .push(let route):
            navigationPath.append(route)
        case .pop:
            if !navigationPath.isEmpty {
                _ = navigationPath.removeLast()
            }
        case .popTo(let route):
            if let index = navigationPath.lastIndex(of: route) {
                navigationPath = Array(navigationPath.prefix(index + 1))
            }
        case .replace(let routes):
            navigationPath = routes
        case .popToRoot:
            if let first = navigationPath.first {
                navigationPath = [first]
            } else {
                navigationPath = []
            }
        case .pushAll(let routes):
            navigationPath.append(contentsOf: routes)
        case .popCount(let count):
            if count > 0, count <= navigationPath.count {
                navigationPath.removeLast(count)
            }
        case .sequence(let commands):
            for command in commands {
                _ = applyNavigationCommand(command)
            }
        case .whenCancelled(let primary, _):
            _ = applyNavigationCommand(primary)
        }
        return before != navigationPath
    }

    private mutating func applyModalCommand(
        _ command: ModalCommand<PropertyRoute>
    ) -> ModalMutationDelta {
        let oldPath = path
        var delta = ModalMutationDelta()

        switch command {
        case .present(let presentation):
            let modal = ModelModalState(route: presentation.route, style: presentation.style)
            if currentModal == nil {
                currentModal = modal
                delta.presented = true
            } else {
                queuedModals.append(modal)
                delta.queueChanged = true
            }

        case .replaceCurrent(let presentation):
            let modal = ModelModalState(route: presentation.route, style: presentation.style)
            currentModal = modal
            delta.presented = true

        case .dismissCurrent:
            guard currentModal != nil else { return delta }
            delta.dismissed = true
            if queuedModals.isEmpty {
                currentModal = nil
            } else {
                currentModal = queuedModals.removeFirst()
                delta.queueChanged = true
                delta.presented = true
            }

        case .dismissAll:
            let hadCurrent = currentModal != nil
            let hadQueue = !queuedModals.isEmpty
            guard hadCurrent || hadQueue else { return delta }
            delta.dismissed = hadCurrent
            delta.queueChanged = hadQueue
            currentModal = nil
            queuedModals = []
        }

        delta.pathChanged = oldPath != path
        return delta
    }

    private func navigationDecision(
        for command: NavigationCommand<PropertyRoute>,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> PropertyNavigationDecision {
        guard let middlewarePolicy else { return .proceed(command) }
        return middlewarePolicy.navigationDecision(
            for: command,
            state: RouteStack(path: navigationPath)
        )
    }

    private func modalDecision(
        for command: ModalCommand<PropertyRoute>,
        middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
    ) -> PropertyModalDecision {
        guard let middlewarePolicy else { return .proceed(command) }
        return middlewarePolicy.modalDecision(
            for: command,
            currentPresentation: currentModal,
            queuedPresentations: queuedModals
        )
    }

    private mutating func reject(_ reason: FlowRejectionReason) -> FlowStepExpectation {
        lastRejection = reason
        return FlowStepExpectation(outcome: .rejectedOnly(reason))
    }

    private static func isValidPath(_ steps: [RouteStep<PropertyRoute>]) -> Bool {
        let modalIndices = steps.enumerated().filter { $0.element.isModal }.map(\.offset)
        if modalIndices.isEmpty { return true }
        if modalIndices.count > 1 { return false }
        return modalIndices.first == steps.count - 1
    }

    private static func decompose(
        _ steps: [RouteStep<PropertyRoute>]
    ) -> (pushRoutes: [PropertyRoute], modalTail: RouteStep<PropertyRoute>?) {
        guard let last = steps.last, last.isModal else {
            return (steps.map(\.route), nil)
        }
        return (Array(steps.dropLast()).map(\.route), last)
    }
}

enum FlowStepOutcome: Equatable {
    case none
    case pathChangedLast
    case rejectedOnly(FlowRejectionReason)
    case pathChangedThenRejected(FlowRejectionReason)
}

struct FlowStepExpectation: Equatable {
    var outcome: FlowStepOutcome
    var navigationChanged: Bool = false
    var modalPresented: Bool = false
    var modalDismissed: Bool = false
    var modalQueueChanged: Bool = false

    func merged(with other: FlowStepExpectation) -> FlowStepExpectation {
        let mergedOutcome: FlowStepOutcome
        switch (outcome, other.outcome) {
        case (.rejectedOnly(let reason), _):
            mergedOutcome = .rejectedOnly(reason)
        case (.pathChangedThenRejected(let reason), _):
            mergedOutcome = .pathChangedThenRejected(reason)
        case (_, .pathChangedThenRejected(let reason)):
            mergedOutcome = .pathChangedThenRejected(reason)
        case (_, .rejectedOnly(let reason)):
            mergedOutcome = outcome == .pathChangedLast
                ? .pathChangedThenRejected(reason)
                : .rejectedOnly(reason)
        case (.pathChangedLast, _), (_, .pathChangedLast):
            mergedOutcome = .pathChangedLast
        case (.none, .none):
            mergedOutcome = .none
        }

        return FlowStepExpectation(
            outcome: mergedOutcome,
            navigationChanged: navigationChanged || other.navigationChanged,
            modalPresented: modalPresented || other.modalPresented,
            modalDismissed: modalDismissed || other.modalDismissed,
            modalQueueChanged: modalQueueChanged || other.modalQueueChanged
        )
    }
}

struct ModalMutationDelta: Equatable {
    var presented = false
    var dismissed = false
    var queueChanged = false
    var pathChanged = false

    mutating func formUnion(_ other: ModalMutationDelta) {
        presented = presented || other.presented
        dismissed = dismissed || other.dismissed
        queueChanged = queueChanged || other.queueChanged
        pathChanged = pathChanged || other.pathChanged
    }
}

enum ModalResetPreview: Equatable {
    case applied(ModalMutationDelta)
    case rejected(FlowRejectionReason)
}

enum PropertyNavigationDecision {
    case proceed(NavigationCommand<PropertyRoute>)
    case cancel(debugName: String, command: NavigationCommand<PropertyRoute>)
}

enum PropertyModalDecision {
    case proceed(ModalCommand<PropertyRoute>)
    case cancel(debugName: String, command: ModalCommand<PropertyRoute>)
}

struct PropertyMiddlewarePolicy: PropertyFlowMiddlewareModeling {
    static let navigationDebugName = "prop-nav"
    static let modalDebugName = "prop-modal"

    let seed: Int

    func navigationDecision(
        for command: NavigationCommand<PropertyRoute>,
        state: RouteStack<PropertyRoute>
    ) -> PropertyNavigationDecision {
        let score = stableHash(
            "nav|\(seed)|\(navigationSignature(command))|\(state.path.map(\.rawValue).joined(separator: ","))"
        )

        switch command {
        case .push(let route):
            switch score % 7 {
            case 0:
                return .cancel(debugName: Self.navigationDebugName, command: command)
            case 1:
                return .proceed(.push(rotated(route)))
            default:
                return .proceed(command)
            }
        case .replace(let routes):
            switch score % 9 {
            case 0:
                return .cancel(debugName: Self.navigationDebugName, command: command)
            case 1:
                return .proceed(.replace(routes.map(rotated)))
            default:
                return .proceed(command)
            }
        case .pop, .popTo, .popToRoot:
            return score % 11 == 0
                ? .cancel(debugName: Self.navigationDebugName, command: command)
                : .proceed(command)
        default:
            return .proceed(command)
        }
    }

    func modalDecision(
        for command: ModalCommand<PropertyRoute>,
        currentPresentation: ModelModalState?,
        queuedPresentations: [ModelModalState]
    ) -> PropertyModalDecision {
        let current = currentPresentation.map { "\($0.route.rawValue)-\(styleSignature($0.style))" } ?? "nil"
        let queue = queuedPresentations
            .map { "\($0.route.rawValue)-\(styleSignature($0.style))" }
            .joined(separator: ",")
        let score = stableHash(
            "modal|\(seed)|\(modalSignature(command))|\(current)|\(queue)"
        )

        switch command {
        case .present(let presentation):
            switch score % 7 {
            case 0:
                return .cancel(debugName: Self.modalDebugName, command: command)
            case 1:
                return .proceed(
                    .present(
                        ModalPresentation(
                            route: rotated(presentation.route),
                            style: presentation.style
                        )
                    )
                )
            default:
                return .proceed(command)
            }
        case .dismissCurrent, .dismissAll:
            return score % 11 == 0
                ? .cancel(debugName: Self.modalDebugName, command: command)
                : .proceed(command)
        case .replaceCurrent(let presentation):
            switch score % 7 {
            case 0:
                return .cancel(debugName: Self.modalDebugName, command: command)
            case 1:
                return .proceed(
                    .replaceCurrent(
                        ModalPresentation(
                            id: presentation.id,
                            route: rotated(presentation.route),
                            style: presentation.style
                        )
                    )
                )
            default:
                return .proceed(command)
            }
        }
    }

    @MainActor
    func navigationRegistration() -> NavigationMiddlewareRegistration<PropertyRoute> {
        .init(
            middleware: AnyNavigationMiddleware(
                willExecute: { command, state in
                    switch navigationDecision(for: command, state: state) {
                    case .cancel:
                        return .cancel(.middleware(debugName: nil, command: command))
                    case .proceed(let effectiveCommand):
                        return .proceed(effectiveCommand)
                    }
                }
            ),
            debugName: Self.navigationDebugName
        )
    }

    @MainActor
    func modalRegistration() -> ModalMiddlewareRegistration<PropertyRoute> {
        .init(
            middleware: AnyModalMiddleware(
                willExecute: { command, currentPresentation, queuedPresentations in
                    let current = currentPresentation.map {
                        ModelModalState(route: $0.route, style: $0.style)
                    }
                    let queue = queuedPresentations.map {
                        ModelModalState(route: $0.route, style: $0.style)
                    }
                    switch modalDecision(
                        for: command,
                        currentPresentation: current,
                        queuedPresentations: queue
                    ) {
                    case .cancel:
                        return .cancel(.middleware(debugName: nil, command: command))
                    case .proceed(let effectiveCommand):
                        return .proceed(effectiveCommand)
                    }
                }
            ),
            debugName: Self.modalDebugName
        )
    }
}

struct PropertyMiddlewareChainPolicy: PropertyFlowMiddlewareModeling {
    let navigationStages: [PropertyMiddlewarePolicy]
    let modalStages: [PropertyMiddlewarePolicy]

    init(seed: Int, navigationCount: Int = 3, modalCount: Int = 3) {
        self.navigationStages = (0..<navigationCount).map {
            PropertyMiddlewarePolicy(seed: seed &+ (($0 + 1) * 977))
        }
        self.modalStages = (0..<modalCount).map {
            PropertyMiddlewarePolicy(seed: seed &+ (($0 + 1) * 1597))
        }
    }

    func navigationDecision(
        for command: NavigationCommand<PropertyRoute>,
        state: RouteStack<PropertyRoute>
    ) -> PropertyNavigationDecision {
        var currentCommand = command
        for (index, stage) in navigationStages.enumerated() {
            switch stage.navigationDecision(for: currentCommand, state: state) {
            case .cancel(_, let cancelledCommand):
                return .cancel(
                    debugName: navigationDebugName(index: index),
                    command: cancelledCommand
                )
            case .proceed(let updatedCommand):
                currentCommand = updatedCommand
            }
        }
        return .proceed(currentCommand)
    }

    func modalDecision(
        for command: ModalCommand<PropertyRoute>,
        currentPresentation: ModelModalState?,
        queuedPresentations: [ModelModalState]
    ) -> PropertyModalDecision {
        var currentCommand = command
        for (index, stage) in modalStages.enumerated() {
            switch stage.modalDecision(
                for: currentCommand,
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            ) {
            case .cancel(_, let cancelledCommand):
                return .cancel(
                    debugName: modalDebugName(index: index),
                    command: cancelledCommand
                )
            case .proceed(let updatedCommand):
                currentCommand = updatedCommand
            }
        }
        return .proceed(currentCommand)
    }

    @MainActor
    func navigationRegistrations() -> [NavigationMiddlewareRegistration<PropertyRoute>] {
        navigationStages.enumerated().map { index, stage in
            .init(
                middleware: AnyNavigationMiddleware(
                    willExecute: { command, state in
                        switch stage.navigationDecision(for: command, state: state) {
                        case .cancel:
                            return .cancel(.middleware(debugName: nil, command: command))
                        case .proceed(let effectiveCommand):
                            return .proceed(effectiveCommand)
                        }
                    }
                ),
                debugName: navigationDebugName(index: index)
            )
        }
    }

    @MainActor
    func modalRegistrations() -> [ModalMiddlewareRegistration<PropertyRoute>] {
        modalStages.enumerated().map { index, stage in
            .init(
                middleware: AnyModalMiddleware(
                    willExecute: { command, currentPresentation, queuedPresentations in
                        let current = currentPresentation.map {
                            ModelModalState(route: $0.route, style: $0.style)
                        }
                        let queue = queuedPresentations.map {
                            ModelModalState(route: $0.route, style: $0.style)
                        }
                        switch stage.modalDecision(
                            for: command,
                            currentPresentation: current,
                            queuedPresentations: queue
                        ) {
                        case .cancel:
                            return .cancel(.middleware(debugName: nil, command: command))
                        case .proceed(let effectiveCommand):
                            return .proceed(effectiveCommand)
                        }
                    }
                ),
                debugName: modalDebugName(index: index)
            )
        }
    }

    private func navigationDebugName(index: Int) -> String {
        "prop-nav-\(index)"
    }

    private func modalDebugName(index: Int) -> String {
        "prop-modal-\(index)"
    }
}

enum NormalizedFlowEvent: Equatable, Hashable {
    case navigationChanged
    case modalPresented
    case modalDismissed
    case modalQueueChanged
    case intentRejected(FlowRejectionReason)
    case pathChanged

    enum Kind: Equatable, Hashable {
        case navigationChanged
        case modalPresented
        case modalDismissed
        case modalQueueChanged
        case intentRejected
        case pathChanged
    }

    var kind: Kind {
        switch self {
        case .navigationChanged:
            return .navigationChanged
        case .modalPresented:
            return .modalPresented
        case .modalDismissed:
            return .modalDismissed
        case .modalQueueChanged:
            return .modalQueueChanged
        case .intentRejected:
            return .intentRejected
        case .pathChanged:
            return .pathChanged
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .navigationChanged:
            hasher.combine(0)
        case .modalPresented:
            hasher.combine(1)
        case .modalDismissed:
            hasher.combine(2)
        case .modalQueueChanged:
            hasher.combine(3)
        case .intentRejected(let reason):
            hasher.combine(4)
            switch reason {
            case .pushBlockedByModalTail:
                hasher.combine(0)
            case .invalidResetPath:
                hasher.combine(1)
            case .middlewareRejected(let debugName):
                hasher.combine(2)
                hasher.combine(debugName)
            case .reentrantApply:
                hasher.combine(3)
            }
        case .pathChanged:
            hasher.combine(5)
        }
    }
}

func normalizeFlowEvent(_ event: FlowEvent<PropertyRoute>) -> NormalizedFlowEvent? {
    switch event {
    case .pathChanged:
        return .pathChanged
    case .intentRejected(_, let reason):
        return .intentRejected(reason)
    case .navigation(.changed):
        return .navigationChanged
    case .modal(.presented):
        return .modalPresented
    case .modal(.dismissed):
        return .modalDismissed
    case .modal(.queueChanged):
        return .modalQueueChanged
    case .navigation, .modal:
        return nil
    }
}

func normalizedFlowEventMultiset(_ events: [NormalizedFlowEvent]) -> [NormalizedFlowEvent: Int] {
    var counts: [NormalizedFlowEvent: Int] = [:]
    for event in events {
        counts[event, default: 0] += 1
    }
    return counts
}

@MainActor
final class FlowEventRecorder<R: Route> {
    private let events = Mutex<[FlowEvent<R>]>([])
    private var task: Task<Void, Never>?

    init(store: FlowStore<R>) {
        let stream = store.events
        self.task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.events.withLock { $0.append(event) }
            }
        }
    }

    func mark() -> Int {
        events.withLock { $0.count }
    }

    func rawEvents(
        since index: Int,
        minimumCount: Int = 0
    ) async -> [FlowEvent<R>] {
        await waitForMinimumCount(since: index, minimumCount: minimumCount)
        await waitForIdle()
        return events.withLock { Array($0.dropFirst(index)) }
    }

    func cancel() {
        task?.cancel()
    }

    private func waitForMinimumCount(
        since index: Int,
        minimumCount: Int,
        maxPolls: Int = 200,
        pollIntervalNanos: UInt64 = 2_000_000
    ) async {
        guard minimumCount > 0 else { return }

        for _ in 0..<maxPolls {
            let count = events.withLock { $0.count - index }
            if count >= minimumCount {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
    }

    private func waitForIdle(
        maxPolls: Int = 200,
        stablePasses: Int = 4,
        pollIntervalNanos: UInt64 = 2_000_000
    ) async {
        var lastCount = -1
        var stableCount = 0

        for _ in 0..<maxPolls {
            let count = events.withLock { $0.count }
            if count == lastCount {
                stableCount += 1
                if stableCount >= stablePasses {
                    return
                }
            } else {
                lastCount = count
                stableCount = 0
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
    }
}

func minimumExpectedFlowEventCount(_ expectation: FlowStepExpectation) -> Int {
    var count = 0

    if expectation.navigationChanged {
        count += 1
    }
    if expectation.modalPresented {
        count += 1
    }
    if expectation.modalDismissed {
        count += 1
    }
    if expectation.modalQueueChanged {
        count += 1
    }

    switch expectation.outcome {
    case .none:
        break
    case .pathChangedLast:
        count += 1
    case .rejectedOnly:
        count += 1
    case .pathChangedThenRejected:
        count += 2
    }

    return count
}

@MainActor
func runFlowStoreModelComparison(
    seed: Int,
    stepCount: Int,
    store: FlowStore<PropertyRoute>,
    recorder: FlowEventRecorder<PropertyRoute>,
    apply: (inout FlowModelState, FlowIntent<PropertyRoute>) -> FlowStepExpectation
) async {
    var rng = PropertyPBTGenerator(seed: seed)
    var model = FlowModelState()

    for step in 0..<stepCount {
        let intent = randomFlowIntent(rng: &rng)
        let marker = recorder.mark()

        let expectation = apply(&model, intent)
        store.send(intent)

        let events = (
            await recorder.rawEvents(
                since: marker,
                minimumCount: minimumExpectedFlowEventCount(expectation)
            )
        ).compactMap(normalizeFlowEvent)

        assertFlowStoreMatchesModel(
            store: store,
            model: model,
            seed: seed,
            step: step
        )
        assertFlowEventContract(
            events,
            expectation: expectation,
            seed: seed,
            step: step
        )
    }
}

enum PropertyURLCase: CaseIterable {
    case home
    case homeDetail
    case settingsProfile
    case modalLegal
    case homeModalLegal
    case secure
    case homeSecure
    case unknown
    case badSchemeHome
    case badHostHome

    var url: URL {
        switch self {
        case .home:
            return URL(string: "myapp://app/home")!
        case .homeDetail:
            return URL(string: "myapp://app/home/detail")!
        case .settingsProfile:
            return URL(string: "myapp://app/settings/profile")!
        case .modalLegal:
            return URL(string: "myapp://app/modal/legal")!
        case .homeModalLegal:
            return URL(string: "myapp://app/home/modal/legal")!
        case .secure:
            return URL(string: "myapp://app/secure")!
        case .homeSecure:
            return URL(string: "myapp://app/home/secure")!
        case .unknown:
            return URL(string: "myapp://app/nowhere")!
        case .badSchemeHome:
            return URL(string: "other://app/home")!
        case .badHostHome:
            return URL(string: "myapp://other/home")!
        }
    }

    var handledPlan: FlowPlan<PropertyRoute>? {
        switch self {
        case .home:
            return FlowPlan(steps: [.push(.home)])
        case .homeDetail:
            return FlowPlan(steps: [.push(.home), .push(.detail)])
        case .settingsProfile:
            return FlowPlan(steps: [.push(.settings), .push(.profile)])
        case .modalLegal:
            return FlowPlan(steps: [.sheet(.legal)])
        case .homeModalLegal:
            return FlowPlan(steps: [.push(.home), .sheet(.legal)])
        case .secure:
            return FlowPlan(steps: [.push(.secure)])
        case .homeSecure:
            return FlowPlan(steps: [.push(.home), .push(.secure)])
        case .unknown, .badSchemeHome, .badHostHome:
            return nil
        }
    }

    func modelDecision(isAuthenticated: Bool) -> FlowDeepLinkDecision<PropertyRoute> {
        switch self {
        case .badSchemeHome:
            return .rejected(reason: .schemeNotAllowed(actualScheme: "other"))
        case .badHostHome:
            return .rejected(reason: .hostNotAllowed(actualHost: "other"))
        case .unknown:
            return .unhandled(url: url)
        case .secure, .homeSecure:
            let plan = handledPlan!
            if isAuthenticated {
                return .flowPlan(plan)
            }
            return .pending(
                FlowPendingDeepLink(url: url, gatedRoute: .secure, plan: plan)
            )
        case .home, .homeDetail, .settingsProfile, .modalLegal, .homeModalLegal:
            return .flowPlan(handledPlan!)
        }
    }
}

enum PropertyReplayAction {
    case handle(PropertyURLCase)
    case resumePending
    case resumePendingIfAllowed(Bool)
    case setAuthenticated(Bool)
    case clearPending
}

struct DeepLinkReplayModelState {
    var flowState = FlowModelState()
    var pendingDeepLink: FlowPendingDeepLink<PropertyRoute>?
    var isAuthenticated = false

    mutating func apply(
        _ action: PropertyReplayAction
    ) -> FlowDeepLinkEffectHandler<PropertyRoute>.Result? {
        switch action {
        case .setAuthenticated(let isAuthenticated):
            self.isAuthenticated = isAuthenticated
            return nil
        case .clearPending:
            pendingDeepLink = nil
            return nil
        case .handle(let urlCase):
            return handle(urlCase)
        case .resumePending:
            return resumePending()
        case .resumePendingIfAllowed(let allow):
            return resumePendingIfAllowed(allow)
        }
    }

    private mutating func handle(
        _ urlCase: PropertyURLCase
    ) -> FlowDeepLinkEffectHandler<PropertyRoute>.Result {
        switch urlCase.modelDecision(isAuthenticated: isAuthenticated) {
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .unhandled(let url):
            return .unhandled(url: url)
        case .pending(let pending):
            pendingDeepLink = pending
            return .pending(pending)
        case .flowPlan(let plan):
            pendingDeepLink = nil
            flowState = FlowModelState(plan: plan)
            return .executed(plan: plan, path: flowState.path)
        }
    }

    private mutating func resumePending() -> FlowDeepLinkEffectHandler<PropertyRoute>.Result {
        guard let pendingDeepLink else {
            return .noPendingDeepLink
        }

        if !isAuthenticated {
            return .pending(pendingDeepLink)
        }

        self.pendingDeepLink = nil
        flowState = FlowModelState(plan: pendingDeepLink.plan)
        return .executed(plan: pendingDeepLink.plan, path: flowState.path)
    }

    private mutating func resumePendingIfAllowed(
        _ allow: Bool
    ) -> FlowDeepLinkEffectHandler<PropertyRoute>.Result {
        guard let pendingDeepLink else {
            return .noPendingDeepLink
        }

        if !allow {
            return .pending(pendingDeepLink)
        }

        return resumePending()
    }
}

@MainActor
func makePropertyFlowMatcher() -> DeepLinkMatcher<FlowPlan<PropertyRoute>> {
    DeepLinkMatcher<FlowPlan<PropertyRoute>> {
        DeepLinkMapping("/home") { _ in
            FlowPlan(steps: [.push(.home)])
        }
        DeepLinkMapping("/home/detail") { _ in
            FlowPlan(steps: [.push(.home), .push(.detail)])
        }
        DeepLinkMapping("/settings/profile") { _ in
            FlowPlan(steps: [.push(.settings), .push(.profile)])
        }
        DeepLinkMapping("/modal/legal") { _ in
            FlowPlan(steps: [.sheet(.legal)])
        }
        DeepLinkMapping("/home/modal/legal") { _ in
            FlowPlan(steps: [.push(.home), .sheet(.legal)])
        }
        DeepLinkMapping("/secure") { _ in
            FlowPlan(steps: [.push(.secure)])
        }
        DeepLinkMapping("/home/secure") { _ in
            FlowPlan(steps: [.push(.home), .push(.secure)])
        }
    }
}

@MainActor
func makePropertyFlowPipeline(
    isAuthenticated: @escaping @Sendable () -> Bool
) -> FlowDeepLinkPipeline<PropertyRoute> {
    FlowDeepLinkPipeline<PropertyRoute>(
        allowedSchemes: ["myapp"],
        allowedHosts: ["app"],
        matcher: makePropertyFlowMatcher(),
        authenticationPolicy: .required(
            shouldRequireAuthentication: { route in route == .secure },
            isAuthenticated: isAuthenticated
        )
    )
}

@MainActor
func assertFlowStoreMatchesModel(
    store: FlowStore<PropertyRoute>,
    model: FlowModelState,
    seed: Int,
    step: Int
) {
    if store.path != model.path {
        Issue.record(
            "seed \(seed) step \(step): flow path mismatch. expected \(model.path), got \(store.path)"
        )
    }

    if store.navigationStore.state.path != model.navigationPath {
        Issue.record(
            "seed \(seed) step \(step): navigation path mismatch. expected \(model.navigationPath), got \(store.navigationStore.state.path)"
        )
    }

    if !presentationsMatch(store.modalStore.currentPresentation, model.currentModal) {
        Issue.record(
            "seed \(seed) step \(step): current modal mismatch. expected \(String(describing: model.currentModal)), got \(String(describing: store.modalStore.currentPresentation))"
        )
    }

    if !queuesMatch(store.modalStore.queuedPresentations, model.queuedModals) {
        Issue.record(
            "seed \(seed) step \(step): queued modal mismatch. expected \(model.queuedModals), got \(store.modalStore.queuedPresentations)"
        )
    }

    let modalCount = store.path.filter { $0.isModal }.count
    if modalCount > 1 {
        Issue.record("seed \(seed) step \(step): flow path contains more than one modal tail: \(store.path)")
    }

    if let modalIndex = store.path.firstIndex(where: { $0.isModal }),
       modalIndex != store.path.count - 1 {
        Issue.record("seed \(seed) step \(step): flow path contains a non-tail modal step: \(store.path)")
    }

    var projected = store.navigationStore.state.path.map(RouteStep.push)
    if let current = store.modalStore.currentPresentation {
        switch current.style {
        case .sheet:
            projected.append(.sheet(current.route))
        case .fullScreenCover:
            projected.append(.cover(current.route))
        }
    }
    if projected != store.path {
        Issue.record(
            "seed \(seed) step \(step): flow path no longer matches inner-store projection. projected \(projected), actual \(store.path)"
        )
    }
}

@MainActor
func assertFlowEventContract(
    _ events: [NormalizedFlowEvent],
    expectation: FlowStepExpectation,
    seed: Int,
    step: Int
) {
    let kinds = events.map(\.kind)

    assertPresence(
        kinds.contains(.navigationChanged) == expectation.navigationChanged,
        seed: seed,
        step: step,
        message: "navigationChanged presence mismatch in \(events)"
    )
    assertPresence(
        kinds.contains(.modalPresented) == expectation.modalPresented,
        seed: seed,
        step: step,
        message: "modalPresented presence mismatch in \(events)"
    )
    assertPresence(
        kinds.contains(.modalDismissed) == expectation.modalDismissed,
        seed: seed,
        step: step,
        message: "modalDismissed presence mismatch in \(events)"
    )
    assertPresence(
        kinds.contains(.modalQueueChanged) == expectation.modalQueueChanged,
        seed: seed,
        step: step,
        message: "modalQueueChanged presence mismatch in \(events)"
    )

    switch expectation.outcome {
    case .none:
        assertPresence(
            !kinds.contains(.pathChanged),
            seed: seed,
            step: step,
            message: "unexpected pathChanged in \(events)"
        )
        assertPresence(
            !kinds.contains(.intentRejected),
            seed: seed,
            step: step,
            message: "unexpected intentRejected in \(events)"
        )

    case .pathChangedLast:
        let pathIndices = kinds.enumerated().filter { $0.element == .pathChanged }.map(\.offset)
        assertPresence(
            pathIndices.count == 1,
            seed: seed,
            step: step,
            message: "expected exactly one pathChanged in \(events)"
        )
        assertPresence(
            !kinds.contains(.intentRejected),
            seed: seed,
            step: step,
            message: "unexpected intentRejected for successful mutation in \(events)"
        )

    case .rejectedOnly(let reason):
        assertPresence(
            !kinds.contains(.pathChanged),
            seed: seed,
            step: step,
            message: "unexpected pathChanged for rejected-only step in \(events)"
        )
        let rejections = events.compactMap { event -> FlowRejectionReason? in
            guard case .intentRejected(let rejection) = event else { return nil }
            return rejection
        }
        assertPresence(
            rejections == [reason],
            seed: seed,
            step: step,
            message: "expected single rejection \(reason), got \(events)"
        )

    case .pathChangedThenRejected(let reason):
        let pathIndices = kinds.enumerated().filter { $0.element == .pathChanged }.map(\.offset)
        let pathIndex = pathIndices.first
        let rejectionIndex = kinds.firstIndex(of: .intentRejected)
        assertPresence(
            pathIndices.count == 1,
            seed: seed,
            step: step,
            message: "expected exactly one pathChanged before rejection in \(events)"
        )
        assertPresence(
            pathIndex != nil && rejectionIndex != nil && pathIndex! < rejectionIndex!,
            seed: seed,
            step: step,
            message: "expected pathChanged before intentRejected in \(events)"
        )
        let rejections = events.compactMap { event -> FlowRejectionReason? in
            guard case .intentRejected(let rejection) = event else { return nil }
            return rejection
        }
        assertPresence(
            rejections == [reason],
            seed: seed,
            step: step,
            message: "expected single rejection \(reason), got \(events)"
        )
    }
}

private func presentationsMatch(
    _ actual: ModalPresentation<PropertyRoute>?,
    _ expected: ModelModalState?
) -> Bool {
    switch (actual, expected) {
    case (nil, nil):
        return true
    case (let actual?, let expected?):
        return actual.route == expected.route && actual.style == expected.style
    default:
        return false
    }
}

private func queuesMatch(
    _ actual: [ModalPresentation<PropertyRoute>],
    _ expected: [ModelModalState]
) -> Bool {
    guard actual.count == expected.count else { return false }
    return zip(actual, expected).allSatisfy { actual, expected in
        actual.route == expected.route && actual.style == expected.style
    }
}

private func assertPresence(
    _ condition: Bool,
    seed: Int,
    step: Int,
    message: String
) {
    if !condition {
        Issue.record("seed \(seed) step \(step): \(message)")
    }
}

private func rotated(_ route: PropertyRoute) -> PropertyRoute {
    let routes = PropertyRoute.allCases
    guard let index = routes.firstIndex(of: route) else { return route }
    return routes[(index + 1) % routes.count]
}

private func stableHash(_ string: String) -> Int {
    var value: UInt64 = 1469598103934665603
    for byte in string.utf8 {
        value ^= UInt64(byte)
        value &*= 1099511628211
    }
    return Int(truncatingIfNeeded: value & 0x7FFF_FFFF_FFFF_FFFF)
}

private func navigationSignature(_ command: NavigationCommand<PropertyRoute>) -> String {
    switch command {
    case .push(let route):
        return "push:\(route.rawValue)"
    case .pushAll(let routes):
        return "pushAll:\(routes.map(\.rawValue).joined(separator: ","))"
    case .pop:
        return "pop"
    case .popCount(let count):
        return "popCount:\(count)"
    case .popToRoot:
        return "popToRoot"
    case .popTo(let route):
        return "popTo:\(route.rawValue)"
    case .replace(let routes):
        return "replace:\(routes.map(\.rawValue).joined(separator: ","))"
    case .sequence(let commands):
        return "sequence:\(commands.map(navigationSignature).joined(separator: "|"))"
    case .whenCancelled(let primary, let fallback):
        return "whenCancelled:\(navigationSignature(primary)):\(navigationSignature(fallback))"
    }
}

private func modalSignature(_ command: ModalCommand<PropertyRoute>) -> String {
    switch command {
    case .present(let presentation):
        return "present:\(presentation.route.rawValue):\(styleSignature(presentation.style))"
    case .replaceCurrent(let presentation):
        return "replaceCurrent:\(presentation.route.rawValue):\(styleSignature(presentation.style))"
    case .dismissCurrent(let reason):
        return "dismissCurrent:\(String(describing: reason))"
    case .dismissAll:
        return "dismissAll"
    }
}

private func styleSignature(_ style: ModalPresentationStyle) -> String {
    switch style {
    case .sheet:
        return "sheet"
    case .fullScreenCover:
        return "cover"
    }
}

struct PropertyNavigationExecutionModelResult {
    let result: NavigationResult<PropertyRoute>
    let stateAfter: RouteStack<PropertyRoute>
    let executedCommands: [NavigationCommand<PropertyRoute>]
    let didExecuteCommands: [NavigationCommand<PropertyRoute>]
}

struct PropertyNavigationTransactionModelResult {
    let transaction: NavigationTransactionResult<PropertyRoute>
    let didExecuteCommands: [NavigationCommand<PropertyRoute>]
    let discardedCommands: [NavigationCommand<PropertyRoute>]
}

private struct PropertyNavigationLeafModelResult {
    let result: NavigationResult<PropertyRoute>
    let stateAfter: RouteStack<PropertyRoute>
    let executedCommands: [NavigationCommand<PropertyRoute>]
    let finalizedCommand: NavigationCommand<PropertyRoute>
}

func modelNavigationExecute(
    _ command: NavigationCommand<PropertyRoute>,
    initialState: RouteStack<PropertyRoute> = .init(),
    middlewarePolicy: (any PropertyFlowMiddlewareModeling)? = nil,
    engine: NavigationEngine<PropertyRoute> = .init()
) -> PropertyNavigationExecutionModelResult {
    switch command {
    case .sequence(let commands):
        var currentState = initialState
        var executedCommands: [NavigationCommand<PropertyRoute>] = []
        var didExecuteCommands: [NavigationCommand<PropertyRoute>] = []
        var results: [NavigationResult<PropertyRoute>] = []

        for nestedCommand in commands {
            let outcome = modelNavigationExecute(
                nestedCommand,
                initialState: currentState,
                middlewarePolicy: middlewarePolicy,
                engine: engine
            )
            currentState = outcome.stateAfter
            executedCommands.append(contentsOf: outcome.executedCommands)
            didExecuteCommands.append(contentsOf: outcome.didExecuteCommands)
            results.append(outcome.result)
        }

        return PropertyNavigationExecutionModelResult(
            result: .multiple(results),
            stateAfter: currentState,
            executedCommands: executedCommands,
            didExecuteCommands: didExecuteCommands
        )

    case .whenCancelled(let primary, let fallback):
        let primaryOutcome = modelNavigationExecute(
            primary,
            initialState: initialState,
            middlewarePolicy: middlewarePolicy,
            engine: engine
        )
        if primaryOutcome.result.isSuccess {
            return primaryOutcome
        }

        let fallbackOutcome = modelNavigationExecute(
            fallback,
            initialState: initialState,
            middlewarePolicy: middlewarePolicy,
            engine: engine
        )
        return PropertyNavigationExecutionModelResult(
            result: fallbackOutcome.result,
            stateAfter: fallbackOutcome.result.isSuccess ? fallbackOutcome.stateAfter : initialState,
            executedCommands: primaryOutcome.executedCommands + fallbackOutcome.executedCommands,
            didExecuteCommands: primaryOutcome.didExecuteCommands + fallbackOutcome.didExecuteCommands
        )

    default:
        let leaf = modelNavigationLeaf(
            command,
            initialState: initialState,
            middlewarePolicy: middlewarePolicy,
            engine: engine
        )
        return PropertyNavigationExecutionModelResult(
            result: leaf.result,
            stateAfter: leaf.stateAfter,
            executedCommands: leaf.executedCommands,
            didExecuteCommands: [leaf.finalizedCommand]
        )
    }
}

func modelNavigationTransaction(
    _ commands: [NavigationCommand<PropertyRoute>],
    initialState: RouteStack<PropertyRoute> = .init(),
    middlewarePolicy: (any PropertyFlowMiddlewareModeling)? = nil,
    engine: NavigationEngine<PropertyRoute> = .init()
) -> PropertyNavigationTransactionModelResult {
    var shadowState = initialState
    var leafOutcomes: [PropertyNavigationLeafModelResult] = []
    var failureIndex: Int?

    for (index, command) in commands.enumerated() {
        let outcome = modelNavigationLeaf(
            command,
            initialState: shadowState,
            middlewarePolicy: middlewarePolicy,
            engine: engine
        )
        leafOutcomes.append(outcome)
        shadowState = outcome.stateAfter
        if !outcome.result.isSuccess {
            failureIndex = index
            break
        }
    }

    let isCommitted = !commands.isEmpty && failureIndex == nil
    let transaction = NavigationTransactionResult<PropertyRoute>(
        requestedCommands: commands,
        executedCommands: leafOutcomes.flatMap(\.executedCommands),
        results: leafOutcomes.map(\.result),
        stateBefore: initialState,
        stateAfter: isCommitted ? shadowState : initialState,
        failureIndex: failureIndex,
        isCommitted: isCommitted
    )

    return PropertyNavigationTransactionModelResult(
        transaction: transaction,
        didExecuteCommands: isCommitted ? leafOutcomes.map(\.finalizedCommand) : [],
        discardedCommands: isCommitted ? [] : leafOutcomes.map(\.finalizedCommand)
    )
}

private func modelNavigationLeaf(
    _ command: NavigationCommand<PropertyRoute>,
    initialState: RouteStack<PropertyRoute>,
    middlewarePolicy: (any PropertyFlowMiddlewareModeling)?,
    engine: NavigationEngine<PropertyRoute>
) -> PropertyNavigationLeafModelResult {
    let effectiveCommand = applyNavigationMiddlewarePolicy(
        command,
        state: initialState,
        middlewarePolicy: middlewarePolicy
    )

    switch effectiveCommand {
    case .cancel(let commandToFinalize, let reason):
        return PropertyNavigationLeafModelResult(
            result: .cancelled(reason),
            stateAfter: initialState,
            executedCommands: [],
            finalizedCommand: commandToFinalize
        )

    case .proceed(let commandToExecute):
        var shadowState = initialState
        let result = engine.apply(commandToExecute, to: &shadowState)
        return PropertyNavigationLeafModelResult(
            result: result,
            stateAfter: shadowState,
            executedCommands: [commandToExecute],
            finalizedCommand: commandToExecute
        )
    }
}

private enum PropertyNavigationMiddlewareOutcome {
    case proceed(NavigationCommand<PropertyRoute>)
    case cancel(NavigationCommand<PropertyRoute>, NavigationCancellationReason<PropertyRoute>)
}

private func applyNavigationMiddlewarePolicy(
    _ command: NavigationCommand<PropertyRoute>,
    state: RouteStack<PropertyRoute>,
    middlewarePolicy: (any PropertyFlowMiddlewareModeling)?
) -> PropertyNavigationMiddlewareOutcome {
    guard let middlewarePolicy else {
        return .proceed(command)
    }

    switch middlewarePolicy.navigationDecision(for: command, state: state) {
    case .proceed(let effectiveCommand):
        return .proceed(effectiveCommand)
    case .cancel(let debugName, let cancelledCommand):
        return .cancel(
            cancelledCommand,
            .middleware(debugName: debugName, command: cancelledCommand)
        )
    }
}
