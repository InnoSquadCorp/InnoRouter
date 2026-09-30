// MARK: - RouterStoreStackSurface.swift
// InnoRouterSwiftUI - native stack and presentation rendering for RouterStore
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouterCore

@MainActor
struct RouterStoreStackSurface<R: Route, Destination: View, Root: View>: View {
    let scope: RouterScope<R>
    let destination: (R) -> Destination
    let root: () -> Root

    var body: some View {
        content(reconciliationRevision: scope.reconciliationRevision)
    }

    private func content(reconciliationRevision _: UInt64) -> some View {
        RouterStoreModalSurface(
            scope: scope,
            destination: destination
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
    private func presentedDestination(_ presentation: RouterPresentation<R>) -> some View {
        destination(presentation.route)
            .interactiveDismissDisabled(presentation.options.isInteractiveDismissDisabled)
            .onAppear {
                for adaptation in RouterPlatformCapabilities.current.adaptations(
                    for: presentation
                ) {
                    scope.reportPlatformAdaptation(adaptation)
                }
            }
#if os(iOS)
            .routerPresentationOptions(
                presentation.options,
                selection: presentationDetentBinding(for: presentation)
            )
#endif
    }

#if os(iOS)
    private func presentationDetentBinding(
        for presentation: RouterPresentation<R>
    ) -> Binding<PresentationDetent> {
        let canonical = makeRouterPresentationDetentBinding(
            scope: scope,
            presentation: presentation
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
    ) -> Binding<RouterPresentation<R>?> {
        makeRouterPresentationBinding(scope: scope, style: style)
    }
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
                    context: .init(source: .system)
                )
            } else {
                guard let expectedPresentationID else { return }
                scope.dispatch(
                    .dismissPresentation,
                    context: .init(source: .system),
                    executionPrecondition: RouterStore<R>.presentationIdentityPrecondition(
                        id: expectedPresentationID,
                        at: scope.path
                    )
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
    Binding(
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
                executionPrecondition: RouterStore<R>.presentationIdentityPrecondition(
                    id: presentation.id,
                    at: scope.path
                )
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
