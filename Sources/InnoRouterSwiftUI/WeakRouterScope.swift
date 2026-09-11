import InnoRouterCore

@MainActor
final class WeakRouterScope<R: Route> {
    weak var value: RouterScope<R>?

    init(_ value: RouterScope<R>) {
        self.value = value
    }
}

extension RouterStore {
    func compactDeadScopes() {
        scopes = scopes.filter { $0.value.value != nil }
    }

    package var cachedScopeCount: Int {
        compactDeadScopes()
        return scopes.count
    }
}
