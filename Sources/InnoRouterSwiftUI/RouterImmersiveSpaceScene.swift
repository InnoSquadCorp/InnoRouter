import SwiftUI

import InnoRouterCore

@MainActor
protocol RouterImmersiveAppearanceObserver: AnyObject, Sendable {
    func interceptNativeAppearance(_ activation: RouterImmersiveActivation) -> Bool
}

struct RouterImmersiveActivationBinding: Sendable {
    let isAttributed: Bool
    let activation: RouterImmersiveActivation?
    var appearanceObserver: (any RouterImmersiveAppearanceObserver)?
}

private struct RouterImmersiveActivationEnvironmentKey: EnvironmentKey {
    static let defaultValue = RouterImmersiveActivationBinding(isAttributed: false, activation: nil)
}

extension EnvironmentValues {
    var routerImmersiveActivationBinding: RouterImmersiveActivationBinding {
        get { self[RouterImmersiveActivationEnvironmentKey.self] }
        set { self[RouterImmersiveActivationEnvironmentKey.self] = newValue }
    }
}

#if os(visionOS)
/// Declares a Router immersive scene whose native callbacks retain their open
/// attempt identity, including callbacks arriving after native failure repair.
///
/// Use this in the app's scene declarations with a matching RouterSceneDriver.
/// Existing id-only ImmersiveSpace declarations retain their original behavior.
@MainActor
public struct RouterImmersiveSpaceScene<R: DestinationRoute & RouterSceneRoute>: Scene {
    private let id: String
    private let store: RouterStore<R>
    private let rendering: RouterHostViewDescriptor<R>?
    private let presentations: RouterPresentationViewCatalog<R>
    private let nativeAppearance: (@MainActor () -> Void)?
    private let nativeDisappearance: (@MainActor () -> Void)?
    private let appearanceObserver: (any RouterImmersiveAppearanceObserver)?

    public init(
        id: String, store: RouterStore<R>, rendering: RouterHostViewDescriptor<R>? = nil,
        presentations: RouterPresentationViewCatalog<R> = .stack
    ) {
        self.id = id
        self.store = store
        self.rendering = rendering
        self.presentations = presentations
        self.nativeAppearance = nil
        self.nativeDisappearance = nil
        self.appearanceObserver = nil
        store.sceneRestorationRegistry.declareAttributedImmersiveSpace(id: id)
    }

    // Native smoke observation stays outside canonical content. The optional
    // internal fault gate can hold admission; it cannot mint an activation.
    init(
        id: String, store: RouterStore<R>,
        nativeAppearance: @escaping @MainActor () -> Void,
        nativeDisappearance: @escaping @MainActor () -> Void,
        appearanceObserver: (any RouterImmersiveAppearanceObserver)? = nil
    ) {
        self.id = id
        self.store = store
        self.rendering = nil
        self.presentations = .stack
        self.nativeAppearance = nativeAppearance
        self.nativeDisappearance = nativeDisappearance
        self.appearanceObserver = appearanceObserver
        store.sceneRestorationRegistry.declareAttributedImmersiveSpace(id: id)
    }

    public var body: some Scene {
        ImmersiveSpace(id: id, for: RouterImmersiveActivation.self) { value in
            RouterImmersiveSpaceHost(
                id: id, store: store, rendering: rendering, presentations: presentations
            )
            .environment(\.routerImmersiveActivationBinding, .init(isAttributed: true, activation: value.wrappedValue, appearanceObserver: appearanceObserver))
            .onAppear {
                RouterSceneLifecycleTrace.record("activation.native.appear", "request=\(String(describing: value.wrappedValue?.requestID)) lifetime=\(String(describing: value.wrappedValue?.lifetime))")
                nativeAppearance?()
            }
            .onDisappear {
                RouterSceneLifecycleTrace.record("activation.native.disappear", "request=\(String(describing: value.wrappedValue?.requestID))")
                nativeDisappearance?()
            }
        }
    }
}
#endif
