import InnoRouterCore

/// Immutable native display input. The captured handle never acquires authority
/// from a later presentation, even if persisted identifiers are reused.
@MainActor
struct RouterTransientPresentationCapture {
    let handle: RouterPresentationHandle
    let kind: RouterPresentationFamilyKind
    let content: RouterTransientPresentationContent
    let isCurrent: @MainActor () -> Bool
    /// Starts the Store request for a settled native response. The owning
    /// Store counts it from this call, as it counts a native binding's write,
    /// so a request made later in the same turn cannot commit ahead of it.
    let submit: @MainActor (RouterNativePresentationAttempt.Command) -> Task<Void, Never>

    init?<R: Route>(owner: RouterScope<R>) {
        _ = owner.observedPresentationFamily
        guard owner.matchesCurrentLifetime,
              case .stack(let stack) = owner.store?.state.node(at: owner.path),
              let family = stack.presentationFamily,
              let handle = owner.presentationHandle(), handle.id == family.id else { return nil }
        switch family {
        case .navigation: return nil
        case .alert(let presentation), .confirmationDialog(let presentation):
            self.content = presentation.content
        }
        self.handle = handle
        self.kind = family.kind
        self.isCurrent = { owner.matchesCurrentLifetime && owner.presentationHandle() == handle }
        self.submit = { command in
            owner.startDispatch {
                switch command {
                case .select(let action, let captured):
                    _ = await owner.selectPresentationAction(action, using: captured, context: .init(source: .system))
                case .dismiss(let captured):
                    _ = await owner.dismissPresentation(using: captured, context: .init(source: .system))
                }
            }
        }
    }
}
