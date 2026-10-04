import Foundation

import InnoRouterCore

/// A native presenter's one-shot callback arbitration, not navigation state.
/// The platform adapter supplies an explicit settlement boundary. This type
/// makes no assumption about SwiftUI's binding/button callback ordering.
@MainActor
final class RouterNativePresentationAttempt {
    enum Command: Equatable, Sendable {
        case select(RouterPresentationActionID, RouterPresentationHandle)
        case dismiss(RouterPresentationHandle)
    }

    private enum Phase {
        case open(provisionalDismissal: Bool)
        case selected(RouterPresentationActionID)
        case submitted
        case retired
    }

    let id = UUID()
    let handle: RouterPresentationHandle
    private var phase: Phase = .open(provisionalDismissal: false)

    init(handle: RouterPresentationHandle) { self.handle = handle }

    /// Call synchronously from the native button callback, before launching work.
    func select(_ actionID: RouterPresentationActionID) {
        guard case .open = phase else { return }
        phase = .selected(actionID)
    }

    /// A false binding write is not itself evidence of an independent dismissal.
    func nativeDismissalObserved() {
        guard case .open = phase else { return }
        phase = .open(provisionalDismissal: true)
    }

    /// Called only when the adapter knows this attempt's callbacks have settled.
    /// An adapter without that guarantee must remain unqualified on its platform.
    func settle() -> Command? {
        switch phase {
        case .selected(let action):
            phase = .submitted
            return .select(action, handle)
        case .open(provisionalDismissal: true):
            phase = .submitted
            return .dismiss(handle)
        case .open(provisionalDismissal: false), .submitted, .retired:
            return nil
        }
    }

    /// Rejection/deferral must never reopen an old attempt. If canonical state
    /// still requires display, reconciliation creates a new presenter attempt.
    func retire() { phase = .retired }
}
