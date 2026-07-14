// MARK: - FlowTestStoreTests.swift
// InnoRouterTestingTests - FlowTestStore behavior
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouter
@testable import InnoRouterSwiftUI
import InnoRouterTesting

private enum FlowRoute: Route {
    case landing
    case details
    case sheet
}

@MainActor
private func blockSheetModalMiddleware() -> AnyModalMiddleware<FlowRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in
        if case .present(let presentation) = command, presentation.style == .sheet {
            return .cancel(.middleware(debugName: nil, command: command))
        }
        return .proceed(command)
    })
}

@Suite("FlowTestStore Tests")
struct FlowTestStoreTests {

    @Test(".push emits .navigation(.changed) and .pathChanged events")
    @MainActor
    func pushEmitsNavigationThenPathChange() {
        let store = FlowTestStore<FlowRoute>()

        store.send(.push(.landing))

        store.receiveNavigation { event in
            if case .changed(_, let to) = event { return to.path == [.landing] }
            return false
        }
        store.receivePathChanged { old, new in
            old.isEmpty && new == [.push(.landing)]
        }
        store.finish()
    }

    @Test(".presentSheet emits .modal(.presented) → .modal(.commandIntercepted) → .pathChanged")
    @MainActor
    func presentSheetEmitsModalThenPath() {
        let store = FlowTestStore<FlowRoute>()

        store.send(.presentSheet(.sheet))

        // FlowStore uses commitFlowPreview: onPresented fires before onCommandIntercepted,
        // and pathChanged fires after the modal commit completes.
        store.receiveModal { event in
            if case .presented(let presentation) = event { return presentation.route == .sheet }
            return false
        }
        store.receiveModal { event in
            if case .commandIntercepted(_, .executed) = event { return true }
            return false
        }
        store.receivePathChanged { _, new in new == [.sheet(.sheet)] }
        store.finish()
    }

    @Test("Push after modal tail emits .intentRejected(.pushBlockedByModalTail), no path change")
    @MainActor
    func pushAfterModalTailRejected() {
        let store = FlowTestStore<FlowRoute>()

        store.send(.presentSheet(.sheet))
        store.skipReceivedEvents()

        store.send(.push(.details))

        store.receiveIntentRejected(
            intent: .push(.details),
            reason: .pushBlockedByModalTail
        )
        #expect(store.path == [.sheet(.sheet)])
        store.finish()
    }

    @Test("End-to-end: sheet-blocking modal middleware cancels FlowStore presentSheet")
    @MainActor
    func sheetMiddlewareCancelEndToEnd() {
        let store = FlowTestStore<FlowRoute>(
            configuration: FlowStoreConfiguration(
                modal: ModalStoreConfiguration(
                    middlewares: [ModalMiddlewareRegistration(middleware: blockSheetModalMiddleware(), debugName: "BlockSheet")]
                )
            )
        )

        store.send(.presentSheet(.sheet))

        // FlowStore takes the preview-only path for cancelled middleware outcomes —
        // it never commits, so no modal.* events fire. Only .intentRejected does.
        store.receiveIntentRejected(
            intent: .presentSheet(.sheet),
            reason: .middlewareRejected(debugName: "BlockSheet")
        )

        #expect(store.path.isEmpty)
        #expect(store.store.navigationStore.state.path.isEmpty)
        #expect(store.store.modalStore.currentPresentation == nil)
        store.finish()
    }

    @Test("Navigation path mismatch surfaces through FlowTestStore in FIFO order")
    @MainActor
    func navigationPathMismatchEmitsNavigationThenPathChange() {
        let store = FlowTestStore<FlowRoute>()

        store.send(.push(.landing))
        store.skipReceivedEvents()

        store.store.navigationStore.pathBinding.wrappedValue = [.details]

        store.receiveNavigation { event in
            if case .pathMismatch(let mismatch) = event {
                return mismatch.oldPath == [.landing] && mismatch.newPath == [.details]
            }
            return false
        }
        store.receiveNavigation { event in
            if case .changed(let old, let new) = event {
                return old.path == [.landing] && new.path == [.details]
            }
            return false
        }
        store.receivePathChanged { old, new in
            old == [.push(.landing)] && new == [.push(.details)]
        }
        #expect(store.path == [.push(.details)])
        #expect(store.store.navigationStore.state.path == [.details])
        store.finish()
    }
}
