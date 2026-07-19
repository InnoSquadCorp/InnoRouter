// MARK: - FlowStoreInvariantTests.swift
// InnoRouterTests - FlowStore path invariants
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum FlowRoute: Route {
    case login
    case terms
    case welcome
    case settings
}

@Suite("FlowStore Invariant Tests")
struct FlowStoreInvariantTests {

    @Test("push is rejected while modal tail is active and emits pushBlockedByModalTail")
    @MainActor
    func pushBlockedByModalTail() {
        let rejections = Mutex<[(FlowIntent<FlowRoute>, FlowRejectionReason)]>([])
        let store = FlowStore<FlowRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )

        store.send(.push(.login))
        store.send(.presentSheet(.terms))
        // Attempt an illegal push while modal tail is active.
        store.send(.push(.welcome))

        #expect(store.path == [.push(.login), .sheet(.terms)])
        let captured = rejections.withLock { $0 }
        #expect(captured.count == 1)
        if let rejection = captured.first {
            #expect(rejection.0 == .push(.welcome))
            #expect(rejection.1 == .pushBlockedByModalTail)
        }
    }

    @Test("reset with more than one modal step is rejected")
    @MainActor
    func resetRejectsMultipleModals() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let store = FlowStore<FlowRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .intentRejected(_, let reason) = event else { return }
                    rejections.withLock { $0.append(reason) }
                }
            )
        )

        store.send(.reset([.push(.login), .sheet(.terms), .sheet(.welcome)]))

        #expect(store.path.isEmpty)
        #expect(rejections.withLock { $0 } == [.invalidResetPath])
    }

    @Test("reset with modal not at tail is rejected")
    @MainActor
    func resetRejectsModalNotAtTail() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let store = FlowStore<FlowRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .intentRejected(_, let reason) = event else { return }
                    rejections.withLock { $0.append(reason) }
                }
            )
        )

        store.send(.reset([.push(.login), .sheet(.terms), .push(.welcome)]))

        #expect(store.path.isEmpty)
        #expect(rejections.withLock { $0 } == [.invalidResetPath])
    }

    @Test("reset with valid path with modal tail applies and emits no rejection")
    @MainActor
    func resetValidModalTailSucceeds() {
        let rejections = Mutex<[FlowRejectionReason]>([])
        let store = FlowStore<FlowRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .intentRejected(_, let reason) = event else { return }
                    rejections.withLock { $0.append(reason) }
                }
            )
        )

        store.send(.reset([.push(.login), .push(.welcome), .sheet(.terms)]))

        #expect(store.path == [.push(.login), .push(.welcome), .sheet(.terms)])
        #expect(rejections.withLock { $0 }.isEmpty)
    }

    @Test("pop on empty stack rejects without changing the path")
    @MainActor
    func popNoOp() {
        let changes = Mutex<Int>(0)
        let rejections = Mutex<[FlowRejectionReason]>([])
        let store = FlowStore<FlowRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .pathChanged:
                        changes.withLock { $0 += 1 }
                    case .intentRejected(_, let reason):
                        rejections.withLock { $0.append(reason) }
                    default:
                        break
                    }
                }
            )
        )

        store.send(.pop)

        #expect(store.path.isEmpty)
        #expect(changes.withLock { $0 } == 0)
        #expect(rejections.withLock { $0 } == [.middlewareRejected(debugName: nil)])
    }

    @Test("dismiss with no modal tail is silent no-op")
    @MainActor
    func dismissNoOp() {
        let changes = Mutex<Int>(0)
        let rejections = Mutex<Int>(0)
        let store = FlowStore<FlowRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .pathChanged:
                        changes.withLock { $0 += 1 }
                    case .intentRejected:
                        rejections.withLock { $0 += 1 }
                    default:
                        break
                    }
                }
            )
        )
        store.send(.push(.login))
        changes.withLock { $0 = 0 }

        store.send(.dismiss)

        #expect(store.path == [.push(.login)])
        #expect(changes.withLock { $0 } == 0)
        #expect(rejections.withLock { $0 } == 0)
    }

    @Test("invalid initial path is treated as empty")
    @MainActor
    func invalidInitialPathCoercedToEmpty() {
        let store = FlowStore<FlowRoute>(
            initial: [.sheet(.login), .push(.welcome)]
        )
        #expect(store.path.isEmpty)
    }

    @Test("invalid initial path emits its typed validation diagnostic")
    @MainActor
    func invalidInitialPathEmitsTypedDiagnostic() {
        var diagnostics: [FlowPlanValidationError] = []

        let modalNotAtTail = FlowStore<FlowRoute>.validatedInitial(
            [.sheet(.login), .push(.welcome)],
            onInvalid: { diagnostics.append($0) }
        )
        let tooManyModals = FlowStore<FlowRoute>.validatedInitial(
            [.sheet(.login), .cover(.terms)],
            onInvalid: { diagnostics.append($0) }
        )

        #expect(modalNotAtTail.isEmpty)
        #expect(tooManyModals.isEmpty)
        #expect(diagnostics == [.modalNotAtTail, .tooManyModals])
    }

    @Test("validating initial path throws instead of silently coercing invalid input")
    @MainActor
    func validatingInitialPathThrowsOnInvalidInput() {
        do {
            _ = try FlowStore<FlowRoute>(
                validating: [.sheet(.login), .push(.welcome)]
            )
            Issue.record("Expected FlowPlanValidationError.modalNotAtTail")
        } catch let error as FlowPlanValidationError {
            #expect(error == .modalNotAtTail)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("validating initial path preserves valid modal tail state")
    @MainActor
    func validatingInitialPathPreservesValidState() throws {
        let store = try FlowStore<FlowRoute>(
            validating: [.push(.login), .sheet(.terms)]
        )
        #expect(store.path == [.push(.login), .sheet(.terms)])
    }
}
