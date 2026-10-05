#if os(watchOS)
import SwiftUI
import WatchKit

import InnoRouterCore

/// WatchKit dismisses an alert before invoking its action handler. Supplying
/// the otherwise implicit Cancel action also gives dismissal an explicit event.
@MainActor
struct RouterWatchTransientPresenter: View {
    let presentation: RouterTransientPresentationCapture?
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = Coordinator()

    var body: some View {
        Color.clear
            .onAppear { coordinator.update(presentation) }
            .onChange(of: presentation?.handle) { _, _ in coordinator.update(presentation) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { coordinator.update(presentation) }
            }
            .onDisappear { coordinator.update(nil) }
    }

    @MainActor
    final class Coordinator {
        private var desired: RouterTransientPresentationCapture?
        private var active: RouterNativePresentationAttempt?
        private weak var controller: WKInterfaceController?
        private var isPresented = false

        func update(_ presentation: RouterTransientPresentationCapture?) {
            desired = presentation
            reconcile()
        }

        private func reconcile() {
            if let active {
                guard desired?.handle != active.handle || desired?.isCurrent() != true else { return }
                active.retire()
                if isPresented { controller?.dismiss() }
                self.active = nil
                isPresented = false
            }
            guard let desired, desired.isCurrent(),
                  let controller = WKApplication.shared().visibleInterfaceController else { return }
            let attempt = RouterNativePresentationAttempt(handle: desired.handle)
            self.active = attempt
            self.controller = controller
            isPresented = true
            var actions = desired.content.actions.map { action in
                WKAlertAction(title: action.label, style: action.role.watchKitStyle) { [weak self] in
                    attempt.select(action.id)
                    self?.submit(attempt, capture: desired)
                }
            }
            if desired.kind == .confirmationDialog && !desired.content.actions.contains(where: { $0.role == .cancel }) {
                actions.append(WKAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] in
                    attempt.nativeDismissalObserved()
                    self?.submit(attempt, capture: desired)
                })
            }
            controller.presentAlert(
                withTitle: desired.content.title, message: desired.content.message,
                preferredStyle: desired.kind == .alert ? .alert : .actionSheet, actions: actions
            )
        }

        private func submit(
            _ attempt: RouterNativePresentationAttempt,
            capture: RouterTransientPresentationCapture
        ) {
            guard active === attempt, let command = attempt.settle() else { return }
            isPresented = false
            Task { [weak self] in
                await capture.submit(command)
                guard let self, self.active === attempt else { return }
                attempt.retire()
                self.active = nil
                self.reconcile()
            }
        }
    }
}

private extension RouterPresentationActionRole {
    var watchKitStyle: WKAlertActionStyle {
        switch self {
        case .normal: .default
        case .cancel: .cancel
        case .destructive: .destructive
        }
    }
}
#endif
