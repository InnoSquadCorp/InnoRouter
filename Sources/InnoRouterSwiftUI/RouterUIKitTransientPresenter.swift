#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

import InnoRouterCore

/// UIKit resolves selection and action-sheet cancellation through action
/// handlers. A SwiftUI binding write is never used as a settlement signal.
@MainActor
struct RouterUIKitTransientPresenter: UIViewControllerRepresentable {
    let presentation: RouterTransientPresentationCapture?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        context.coordinator.anchor = anchor
        anchor.appeared = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        return anchor
    }

    func updateUIViewController(_ controller: Anchor, context: Context) {
        context.coordinator.desired = presentation
        context.coordinator.reconcile()
    }

    static func dismantleUIViewController(_ controller: Anchor, coordinator: Coordinator) {
        coordinator.desired = nil
        coordinator.retire()
        controller.appeared = nil
    }

    final class Anchor: UIViewController {
        var appeared: (() -> Void)?
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            appeared?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var anchor: Anchor?
        var desired: RouterTransientPresentationCapture?
        private var active: RouterNativePresentationAttempt?
        private var alert: UIAlertController?
        private var isFinishing = false
        private var isOutsideCancellation = false
        private var isPresenting = false
        private var pendingFinish: RouterNativePresentationAttempt?

        func reconcile() {
            if let active {
                if desired?.handle != active.handle || desired?.isCurrent() != true { retire() }
                return
            }
            guard !isFinishing else { return }
            guard let desired, desired.isCurrent(), let anchor,
                  anchor.viewIfLoaded?.window != nil,
                  anchor.presentedViewController == nil else { return }
            let attempt = RouterNativePresentationAttempt(handle: desired.handle)
            let controller = makeAlert(desired, attempt: attempt)
            active = attempt
            alert = controller
            isOutsideCancellation = false
            isPresenting = true
            anchor.present(controller, animated: true) {
                self.isPresenting = false
                if let pending = self.pendingFinish {
                    self.pendingFinish = nil
                    self.finish(pending)
                } else {
                    self.reconcile()
                }
            }
        }

        func retire() {
            guard let active else { return }
            active.retire()
            finish(active)
        }

        private func makeAlert(
            _ capture: RouterTransientPresentationCapture,
            attempt: RouterNativePresentationAttempt
        ) -> UIAlertController {
            let controller = UIAlertController(
                title: capture.content.title, message: capture.content.message,
                preferredStyle: capture.kind == .alert ? .alert : .actionSheet
            )
            for action in capture.content.actions {
                controller.addAction(UIAlertAction(title: action.label, style: action.role.uiKitStyle) { [weak self] _ in
                    if action.role == .cancel && self?.isOutsideCancellation == true {
                        attempt.nativeDismissalObserved()
                    } else {
                        attempt.select(action.id)
                    }
                    self?.submit(attempt, capture: capture)
                })
            }
            if capture.kind == .confirmationDialog && !capture.content.actions.contains(where: { $0.role == .cancel }) {
                // UIKit invokes the cancel action when dismissing an iPad
                // action-sheet popover outside its bounds, even though it hides
                // that button. Preserve the declared cancel's typed value when
                // present; an otherwise implicit cancel completes as dismissed.
                controller.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
                    attempt.nativeDismissalObserved()
                    self?.submit(attempt, capture: capture)
                })
            }
            // On iPad an action sheet needs an explicit anchor. The owning
            // stack is the available semantic anchor for programmatic requests.
            if let popover = controller.popoverPresentationController, let anchor {
#if !os(tvOS)
                popover.delegate = self
#endif
                popover.sourceView = anchor.view
                popover.sourceRect = anchor.view.bounds
                popover.permittedArrowDirections = []
            }
            return controller
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === alert else { return }
            isOutsideCancellation = true
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === alert,
                  let active, let desired, active.handle == desired.handle else { return }
            active.nativeDismissalObserved()
            submit(active, capture: desired)
        }

        private func submit(
            _ attempt: RouterNativePresentationAttempt,
            capture: RouterTransientPresentationCapture
        ) {
            guard active === attempt, let command = attempt.settle() else { return }
            isFinishing = true
            Task { [weak self] in
                await capture.submit(command)
                self?.finish(attempt)
            }
        }

        private func finish(_ attempt: RouterNativePresentationAttempt) {
            guard active === attempt else { return }
            isFinishing = true
            // UIKit cannot dismiss an alert while its presentation animation
            // is installing it. Its completion is the explicit native boundary.
            guard !isPresenting else { pendingFinish = attempt; return }
            let completed = { [weak self] in
                guard let self, self.active === attempt else { return }
                attempt.retire()
                self.active = nil
                self.alert = nil
                self.isFinishing = false
                self.reconcile()
            }
            guard let alert else { completed(); return }
            if let transition = alert.transitionCoordinator, alert.isBeingDismissed {
                transition.animate(alongsideTransition: nil) { _ in completed() }
            } else if alert.presentingViewController != nil {
                alert.dismiss(animated: true, completion: completed)
            } else {
                completed()
            }
        }
    }
}

#if !os(tvOS)
extension RouterUIKitTransientPresenter.Coordinator: UIPopoverPresentationControllerDelegate {}
#endif

private extension RouterPresentationActionRole {
    var uiKitStyle: UIAlertAction.Style {
        switch self {
        case .normal: .default
        case .cancel: .cancel
        case .destructive: .destructive
        }
    }
}
#endif
