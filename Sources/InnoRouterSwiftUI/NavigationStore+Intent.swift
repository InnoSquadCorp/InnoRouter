// MARK: - NavigationStore+Intent.swift
// InnoRouterSwiftUI - intent dispatch and the projection of
// NavigationIntent into NavigationCommand plans.
// Copyright © 2026 Inno Squad. All rights reserved.
//
// Extracted from NavigationStore.swift in the 4.1.0 cleanup so the
// store core stays bounded by initialisation, middleware
// management, and command execution. Intent translation stays a
// separate concern with its own audit surface.

import Foundation

import InnoRouterCore

extension NavigationStore {

    /// Dispatches a high-level ``NavigationIntent`` against the
    /// store. The implementation defers to ``commands(for:)``
    /// for the projection so the two surfaces cannot drift.
    public func send(_ intent: NavigationIntent<R>) {
        let plan = commands(for: intent)
        switch plan.count {
        case 0:
            return
        case 1:
            _ = execute(plan[0])
        default:
            _ = executeBatch(plan, stopOnFailure: false)
        }
    }

    /// Projects a ``NavigationIntent`` into the concrete
    /// ``NavigationCommand`` plan that ``send(_:)`` would execute
    /// against the current ``state``.
    ///
    /// Some intents are state-dependent
    /// (`.backBy`, `.backOrPush`, `.pushUniqueRoot`); the projection
    /// is therefore a method on the store rather than an extension on
    /// `NavigationIntent` itself, and reads `state.path` exactly once
    /// to make the decision.
    ///
    /// Returned plans interpret as:
    ///
    /// - empty — no work for the current state (e.g.
    ///   `.pushUniqueRoot` of a route already on the stack).
    /// - single element — a single `.execute(_:)` call's worth.
    /// - multiple elements — a batch the caller can hand to
    ///   `.executeBatch(_:stopOnFailure:)`, exactly the way
    ///   ``send(_:)`` does internally. High-level intents currently
    ///   project to at most one command; the array shape remains useful
    ///   for custom state-dependent projections and source compatibility.
    ///
    /// This accessor surfaces the intent ↔ command projection so
    /// tests and middleware can preview "what would `send(_:)` do"
    /// without inspecting side effects. `send(_:)` is itself
    /// implemented in terms of this projection so the two surfaces
    /// cannot drift.
    public func commands(for intent: NavigationIntent<R>) -> [NavigationCommand<R>] {
        switch intent {
        case .go(let route):
            return [.push(route)]
        case .goMany(let routes):
            switch routes.count {
            case 0:
                return []
            case 1:
                return [.push(routes[0])]
            default:
                return [.pushAll(routes)]
            }
        case .back:
            return [.pop]
        case .backBy(let count):
            if count > 0, count == state.path.count {
                return [.popToRoot]
            } else {
                return [.popCount(count)]
            }
        case .backTo(let route):
            return [.popTo(route)]
        case .backToRoot:
            return [.popToRoot]
        case .replaceStack(let routes):
            return [.replace(routes)]
        case .backOrPush(let route):
            if state.path.contains(route) {
                return [.popTo(route)]
            } else {
                return [.push(route)]
            }
        case .pushUniqueRoot(let route):
            if state.path.contains(route) {
                return []
            } else {
                return [.push(route)]
            }
        }
    }
}
