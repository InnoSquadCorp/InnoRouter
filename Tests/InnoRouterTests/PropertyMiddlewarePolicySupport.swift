// MARK: - PropertyMiddlewarePolicySupport.swift
// InnoRouterTests - deterministic middleware policies for property tests
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouter
@testable import InnoRouterSwiftUI

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
        case .pushAll(let routes):
            switch score % 7 {
            case 0:
                return .cancel(debugName: Self.navigationDebugName, command: command)
            case 1:
                return .proceed(.pushAll(routes.map(rotated)))
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
        case .pop, .popCount, .popTo, .popToRoot:
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
