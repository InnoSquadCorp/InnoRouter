// MARK: - RouterScope+Dispatch.swift
// InnoRouterSwiftUI - immediate commits and ordered fire-and-forget dispatch
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterScope {
    func performImmediately(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        atRoot: Bool
    ) -> RouterOutcome<R>? {
        // A missing Store or an inadmissible scope is reported by the
        // asynchronous path, which already owns those outcomes.
        guard let store, resourceAdmissionRejection == nil else { return nil }
        return store.performImmediately(
            atRoot ? action : action.inScope(path),
            context: context,
            expectedRevision: expectedRevision,
            executionPrecondition: combinedExecutionPrecondition(nil)
        )
    }

    /// Applies `steps` to the state the Store holds when the request runs.
    ///
    /// A transaction is the latest in a sequence of fire-and-forget calls, so
    /// it builds on the requests made before it, including ones that have not
    /// executed yet. A plan built when the call was made would either revert
    /// those requests or be rejected as stale because of them.
    func dispatchTransaction(
        _ steps: [RouterPlanStep<R>],
        resourceBudget: RouterResourceBudget
    ) -> Task<RouterOutcome<R>, Never> {
        let path = path
        let preparation: RouterRequestPreparationBuilder<R> = { state in
            let builder: () -> [RouterPlanStep<R>] = { steps }
            do {
                return .action(.apply(try RouterPlan(from: state, resourceBudget: resourceBudget, builder)))
            } catch let failure as RouterResourceLimitFailure {
                return .rejected(.resourceLimit(failure))
            } catch let failure as RouterHostValidationFailure {
                return .rejected(.hostContract(failure))
            } catch let error as RouterStateValidationError {
                return .rejected(.mutation(.invalidTargetState(error)))
            } catch let error as RouterMutationError {
                return .rejected(.mutation(error))
            } catch {
                return .rejected(.mutation(.incompatibleNavigationTopology(path)))
            }
        }
        if let store, resourceAdmissionRejection == nil, store.canCommitImmediately,
           case .action(let action) = preparation(store.state),
           let outcome = store.performImmediately(
               action, context: .init(), expectedRevision: nil,
               executionPrecondition: combinedExecutionPrecondition(nil), executionPreparation: preparation
           ) {
            return Task { outcome }
        }
        return startDispatch { [self] in
            await performRoot(preparedBy: preparation, context: .init(), executionPrecondition: nil)
        }
    }

    func startDispatch<Output: Sendable>(
        _ work: @escaping @MainActor @Sendable () async -> Output
    ) -> Task<Output, Never> {
        store?.startDispatchTask(work) ?? Task { @MainActor in await work() }
    }
}
