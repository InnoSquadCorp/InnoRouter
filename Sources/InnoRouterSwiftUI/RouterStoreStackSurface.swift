// MARK: - RouterStoreStackSurface.swift
// InnoRouterSwiftUI - native stack and presentation rendering for RouterStore
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouterCore

@MainActor
struct RouterStoreStackSurface<R: Route, Destination: View, Root: View>: View {
    @Environment(\.routerPresentationRendering) private var rendering
    let scope: RouterScope<R>
    let destination: (R) -> Destination
    let root: () -> Root

    var body: some View {
        content(reconciliationRevision: scope.reconciliationRevision)
    }

    private func content(reconciliationRevision _: UInt64) -> some View {
        RouterStoreModalSurface(
            scope: scope,
            destination: destination,
            presentations: rendering[R.self]?.catalog ?? .stack
        ) {
            NavigationStack(path: pathBinding) {
                root()
                    .navigationDestination(for: R.self, destination: destination)
            }
        }
    }

    private var pathBinding: Binding<[R]> {
        Binding(
            get: { scope.observedPath },
            set: { path in
                scope.dispatch(
                    .replaceStack(path),
                    context: .init(source: .system)
                )
            }
        )
    }
}

@MainActor
private struct RouterStoreModalSurface<R: Route, Destination: View, Content: View>: View {
    let scope: RouterScope<R>
    let destination: (R) -> Destination
    let presentations: RouterPresentationViewCatalog<R>
    let content: () -> Content

    var body: some View {
        presentedContent(reconciliationRevision: scope.reconciliationRevision)
    }

    @ViewBuilder
    private func presentedContent(reconciliationRevision _: UInt64) -> some View {
#if os(iOS) || os(tvOS)
        content()
            .sheet(item: presentationBinding(for: .sheet)) { presentation in
                presentedDestination(presentation)
            }
            .fullScreenCover(
                item: presentationBinding(for: .fullScreenCover)
            ) { presentation in
                presentedDestination(presentation)
            }
#if os(iOS)
            .popover(item: presentationBinding(for: .popover)) { presentation in
                presentedDestination(presentation)
            }
#endif
#else
        content()
            .sheet(item: presentationBinding(for: .sheet)) { presentation in
                presentedDestination(presentation)
            }
#endif
    }

    @ViewBuilder
    private func presentedDestination(_ capture: RouterNavigationPresentationCapture<R>) -> some View {
        if let presentation = capture.presentation {
            recursiveDestination(capture)
                .routerNavigationPresentation(capture, catalog: presentations)
                .interactiveDismissDisabled(presentation.options.isInteractiveDismissDisabled)
                .onAppear {
                    guard capture.isCurrent else { return }
                    for adaptation in RouterPlatformCapabilities.current.adaptations(for: presentation) {
                        capture.owner.reportPlatformAdaptation(adaptation)
                    }
                }
#if os(iOS)
                .routerPresentationOptions(
                    presentation.options,
                    selection: presentationDetentBinding(for: capture, presentation: presentation)
                )
#endif
        } else {
            RouterHostRecoveryView(failure: .init(code: .stale, scope: capture.child.path))
        }
    }

    private func recursiveDestination(_ capture: RouterNavigationPresentationCapture<R>) -> AnyView {
        do {
            return try presentations.resolve(capture).render(capture: capture, destination: destination)
        } catch {
            return AnyView(RouterHostRecoveryView(failure: error))
        }
    }

#if os(iOS)
    private func presentationDetentBinding(
        for capture: RouterNavigationPresentationCapture<R>,
        presentation: RouterPresentation<R>
    ) -> Binding<PresentationDetent> {
        let canonical = Binding<RouterPresentationDetent>(
            get: { capture.presentation?.options.selectedDetent
                ?? presentation.options.selectedDetent ?? presentation.options.detents.first ?? .large },
            set: { detent in
                capture.owner.dispatch(.setPresentationDetent(detent), context: .init(source: .system),
                                       executionPrecondition: capture.executionPrecondition)
            }
        )
        return Binding(
            get: {
                canonical.wrappedValue.swiftUIPresentationDetent ?? .large
            },
            set: { selected in
                let options = presentation.options
                let detent = options.detents.first {
                    $0.swiftUIPresentationDetent == selected
                } ?? .large
                canonical.wrappedValue = detent
            }
        )
    }
#endif

    private func presentationBinding(
        for style: RouterPresentationStyle?
    ) -> Binding<RouterNavigationPresentationCapture<R>?> {
        makeRouterNativeNavigationPresentationBinding(scope: scope, style: style)
    }
}

/// Native identity is the captured incarnation, not its persistable UUID.
/// Old binding callbacks retain their old fence even when a restored value
/// reuses the same presentation ID and child path.
@MainActor
func makeRouterNativeNavigationPresentationBinding<R: Route>(
    scope: RouterScope<R>, style: RouterPresentationStyle?
) -> Binding<RouterNavigationPresentationCapture<R>?> {
    let capture = RouterNavigationPresentationCapture(owner: scope).flatMap { capture in
        guard let presentation = capture.presentation,
              RouterPlatformCapabilities.current.effectivePresentationStyle(for: presentation.style) == style else { return nil as RouterNavigationPresentationCapture<R>? }
        return capture
    }
    return Binding(
        get: { capture?.isCurrent == true ? capture : nil },
        set: { value in
            guard case nil = value, let capture else { return }
            scope.dispatch(.dismissPresentation, context: .init(source: .system),
                           executionPrecondition: capture.executionPrecondition)
        }
    )
}

@MainActor
package func makeRouterPresentationBinding<R: Route>(
    scope: RouterScope<R>,
    style: RouterPresentationStyle?
) -> Binding<RouterPresentation<R>?> {
    let expectedPresentationID = scope.observedPresentation.flatMap { presentation in
        let effectiveStyle = RouterPlatformCapabilities.current
            .effectivePresentationStyle(for: presentation.style)
        return effectiveStyle == style ? presentation.id : nil
    }
    let lifetimePrecondition = expectedPresentationID.map { scope.presentationLifetimePrecondition(id: $0) }
    return Binding<RouterPresentation<R>?>(
        get: {
            guard let presentation = scope.observedPresentation else {
                return nil
            }
            let effectiveStyle = RouterPlatformCapabilities.current
                .effectivePresentationStyle(for: presentation.style)
            return effectiveStyle == style ? presentation : nil
        },
        set: { presentation in
            if let presentation {
                scope.dispatch(
                    .present(presentation),
                    context: .init(source: .system),
                    executionPrecondition: lifetimePrecondition
                )
            } else {
                guard expectedPresentationID != nil else { return }
                scope.dispatch(
                    .dismissPresentation,
                    context: .init(source: .system),
                    executionPrecondition: lifetimePrecondition
                )
            }
        }
    )
}

@MainActor
package func makeRouterPresentationDetentBinding<R: Route>(
    scope: RouterScope<R>,
    presentation: RouterPresentation<R>
) -> Binding<RouterPresentationDetent> {
    let lifetimePrecondition = scope.presentationLifetimePrecondition(id: presentation.id)
    return Binding(
        get: {
            guard scope.observedPresentation?.id == presentation.id,
                  let selected = scope.observedPresentation?.options.selectedDetent else {
                return presentation.options.selectedDetent
                    ?? presentation.options.detents.first
                    ?? .large
            }
            return selected
        },
        set: { detent in
            scope.dispatch(
                .setPresentationDetent(detent),
                context: .init(source: .system),
                executionPrecondition: lifetimePrecondition
            )
        }
    )
}

#if os(iOS)
private extension View {
    func routerPresentationOptions(
        _ options: RouterPresentationOptions,
        selection: Binding<PresentationDetent>
    ) -> some View {
        let detents = Set(options.detents.compactMap(\.swiftUIPresentationDetent))
        return self
            .presentationDetents(detents.isEmpty ? [.large] : detents, selection: selection)
            .presentationDragIndicator(options.dragIndicator.swiftUIVisibility)
            .presentationCompactAdaptation(options.compactAdaptation.swiftUIAdaptation)
            .presentationBackgroundInteraction(options.backgroundInteraction.swiftUIInteraction)
            .presentationContentInteraction(options.contentInteraction.swiftUIInteraction)
            .presentationCornerRadius(options.cornerRadius.map { CGFloat($0) })
    }
}

private extension RouterPresentationOptions {
    var selectedSwiftUIDetent: PresentationDetent {
        selectedDetent?.swiftUIPresentationDetent
            ?? detents.first?.swiftUIPresentationDetent
            ?? .large
    }
}

private extension RouterPresentationDetent {
    var swiftUIPresentationDetent: PresentationDetent? {
        switch self {
        case .medium: .medium
        case .large: .large
        case .height(let value): value > 0 ? .height(value) : nil
        case .fraction(let value):
            (0...1).contains(value) && value > 0 ? .fraction(value) : nil
        }
    }
}

private extension RouterDragIndicatorVisibility {
    var swiftUIVisibility: Visibility {
        switch self {
        case .automatic: .automatic
        case .visible: .visible
        case .hidden: .hidden
        }
    }
}

private extension RouterCompactAdaptation {
    var swiftUIAdaptation: PresentationAdaptation {
        switch self {
        case .automatic: .automatic
        case .sheet: .sheet
        case .popover: .popover
        case .fullScreenCover: .fullScreenCover
        }
    }
}

private extension RouterPresentationBackgroundInteraction {
    var swiftUIInteraction: PresentationBackgroundInteraction {
        switch self {
        case .automatic: .automatic
        case .enabled: .enabled
        case .enabledUpThrough(let detent):
            detent.swiftUIPresentationDetent.map {
                .enabled(upThrough: $0)
            } ?? .automatic
        case .disabled: .disabled
        }
    }
}

private extension RouterPresentationContentInteraction {
    var swiftUIInteraction: PresentationContentInteraction {
        switch self {
        case .automatic: .automatic
        case .resizes: .resizes
        case .scrolls: .scrolls
        }
    }
}
#endif
