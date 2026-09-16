import Foundation
import SwiftUI

import InnoRouterCore

public extension View {
    /// Activates an app-owned restoration driver while this root view is live.
    ///
    /// The modifier saves immediately when the scene leaves the active phase.
    /// Restore and save failures remain visible through the driver's `status`.
    @MainActor
    func routerStateRestoration<R: Route & Codable>(
        _ driver: RouterRestorationDriver<R>
    ) -> some View {
        modifier(RouterStateRestorationModifier(driver: driver))
    }
}

@MainActor
private struct RouterStateRestorationModifier<R: Route & Codable>: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var attachmentID = UUID()
    @State private var attachedDriver: RouterRestorationDriver<R>?
    let driver: RouterRestorationDriver<R>

    func body(content: Content) -> some View {
        content
            .task(id: ObjectIdentifier(driver)) {
                if let attachedDriver, attachedDriver !== driver {
                    attachedDriver.detach(attachmentID)
                }
                attachedDriver = driver
                _ = try? await driver.attach(attachmentID)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                Task { @MainActor in
                    try? await driver.save()
                }
            }
            .onDisappear {
                driver.detach(attachmentID)
                if attachedDriver === driver {
                    attachedDriver = nil
                }
            }
    }
}
