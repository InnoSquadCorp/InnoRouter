import SwiftUI

import InnoRouterCore

/// Environment-free modal rendering surface shared by public hosts.
///
/// Keeping dispatcher publication out of this type lets `FlowHost` render the
/// modal UI owned by its inner store while preserving `FlowStore` as the sole
/// mutation authority.
struct ModalPresentationSurface<M: Route, Destination: View, Content: View>: View {
    @Bindable private var store: ModalStore<M>
    private let destination: (M) -> Destination
    private let content: () -> Content

    init(
        store: ModalStore<M>,
        @ViewBuilder destination: @escaping (M) -> Destination,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.store = store
        self.destination = destination
        self.content = content
    }

    var body: some View {
        let modalStore = store

        Group {
            // MARK: - Platform: .fullScreenCover is only available on iOS and tvOS.
            // On macOS, watchOS, and visionOS the cover request degrades to a sheet,
            // so the store's binding routes both presentation styles through a single
            // .sheet modifier. This keeps the store-level vocabulary platform-neutral:
            // callers always issue .fullScreenCover and the host honours or degrades.
#if os(iOS) || os(tvOS)
            content()
                .sheet(item: modalStore.binding(for: .sheet)) { presentation in
                    destination(presentation.route)
                }
                .fullScreenCover(item: modalStore.binding(for: .fullScreenCover)) { presentation in
                    destination(presentation.route)
                }
#else
            // macOS / watchOS / visionOS: .fullScreenCover is unavailable. Treat any
            // fullScreenCover request as a sheet, because all three platforms expose
            // sheet presentation as their native modal primitive.
            content()
                .sheet(item: modalStore.binding(for: [.sheet, .fullScreenCover])) { presentation in
                    destination(presentation.route)
                }
#endif
        }
    }
}

/// Hosts modal presentation surfaces backed by a `ModalStore`.
///
/// Ownership split:
///
/// - The `ModalStore` is owned by the caller and outlives this host.
/// - The store caches the handler published through ``EnvironmentRouter``, so
///   the host does not allocate a fresh closure per render.
/// - A nested host replaces the complete authority for the matching route
///   type, preventing accidental capability merging across host boundaries.
public struct ModalHost<M: Route, Destination: View, Content: View>: View {
    @Bindable private var store: ModalStore<M>
    private let destination: (M) -> Destination
    private let content: () -> Content

    /// Creates a modal host with destination and content builders.
    public init(
        store: ModalStore<M>,
        @ViewBuilder destination: @escaping (M) -> Destination,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.store = store
        self.destination = destination
        self.content = content
    }

    public var body: some View {
        let modalStore = store

        ModalPresentationSurface(
            store: modalStore,
            destination: destination,
            content: content
        )
            .routerAuthority(
                for: M.self,
                modal: modalStore.intentDispatcher
            )
    }
}
