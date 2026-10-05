#if os(macOS)
import AppKit
import SwiftUI

import InnoRouterCore

/// AppKit supplies one modal response after its sheet ends. Unlike a SwiftUI
/// binding notification, this response identifies the selected button.
@MainActor
struct RouterAppKitTransientPresenter: NSViewRepresentable {
    let presentation: RouterTransientPresentationCapture?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        context.coordinator.anchor = anchor
        anchor.moved = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        return anchor
    }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.desired = presentation
        context.coordinator.reconcile()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        coordinator.desired = nil
        coordinator.retire()
        view.moved = nil
    }

    final class Anchor: NSView {
        var moved: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moved?()
        }
    }

    @MainActor
    final class Coordinator {
        weak var anchor: Anchor?
        var desired: RouterTransientPresentationCapture?
        private var active: RouterNativePresentationAttempt?
        private var alert: NSAlert?

        func reconcile() {
            if let active {
                if desired?.handle != active.handle || desired?.isCurrent() != true { retire() }
                return
            }
            guard let desired, desired.isCurrent(), let window = anchor?.window,
                  window.attachedSheet == nil else { return }
            let attempt = RouterNativePresentationAttempt(handle: desired.handle)
            let alert = makeAlert(desired.content)
            self.active = attempt
            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.completed(response, capture: desired, attempt: attempt)
            }
        }

        func retire() {
            guard let active else { return }
            active.retire()
            if let alert, let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .abort)
            } else {
                finish(active)
            }
        }

        private func makeAlert(_ content: RouterTransientPresentationContent) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = content.title
            alert.informativeText = content.message ?? ""
            alert.alertStyle = .informational
            for action in content.actions {
                let button = alert.addButton(withTitle: action.label)
                button.hasDestructiveAction = action.role == .destructive
                if action.role == .cancel { button.keyEquivalent = "\u{1b}" }
            }
            return alert
        }

        private func completed(
            _ response: NSApplication.ModalResponse,
            capture: RouterTransientPresentationCapture,
            attempt: RouterNativePresentationAttempt
        ) {
            guard active === attempt else { return }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if capture.content.actions.indices.contains(index) {
                attempt.select(capture.content.actions[index].id)
            } else {
                attempt.nativeDismissalObserved()
            }
            guard let command = attempt.settle() else { finish(attempt); return }
            Task { [weak self] in
                await capture.submit(command)
                self?.finish(attempt)
            }
        }

        private func finish(_ attempt: RouterNativePresentationAttempt) {
            guard active === attempt else { return }
            attempt.retire()
            active = nil
            alert = nil
            reconcile()
        }
    }
}
#endif
