import Testing

import InnoRouter
import InnoRouterInspector

private enum LifecycleRoute: Route {
    case detail
}

@Suite("Router object lifecycles")
@MainActor
struct RouterLifecycleTests {
    @Test("Store and cached scopes do not form a retain cycle")
    func storeScopeCycle() {
        var store: RouterStore<LifecycleRoute>? = RouterStore()
        var scope: RouterScope<LifecycleRoute>? = store!.scope()
        weak let weakStore = store
        weak let weakScope = scope

        store = nil
        #expect(weakStore == nil)
        #expect(scope?.state == nil)

        scope = nil
        #expect(weakScope == nil)
    }

    @Test("Inspector subscriptions never retain their recorder")
    func inspectorSubscriptionOwnership() {
        let store = RouterStore<LifecycleRoute>()
        var recorder: RouterInspectorRecorder? = RouterInspectorRecorder()
        let subscription = recorder!.attach(to: store)
        weak let weakRecorder = recorder

        recorder = nil

        #expect(weakRecorder == nil)
        subscription.cancel()
    }
}
