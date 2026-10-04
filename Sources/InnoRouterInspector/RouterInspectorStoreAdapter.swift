import InnoRouterCore
import InnoRouterSwiftUI

@MainActor
public extension RouterInspectorRecorder {
    /// Attaches the canonical InnoRouter 6 transition timeline. The default
    /// formatter records correlation and structural counts while redacting all
    /// route payloads and policy messages.
    @discardableResult
    func attach<R: Route>(
        to store: RouterStore<R>,
        formatter: RouterInspectorFormatter<RouterEvent<R>>? = nil
    ) -> RouterInspectorSubscription {
        attach(
            to: store.events,
            domain: .router,
            formatter: formatter ?? redactedRouterFormatter()
        )
    }
}
