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
        // An observation dependency can outlive the temporary projection that
        // registered it. Keep current graph owners independently of weak scopes;
        // retained missing captures also keep their precise appearance signal.
        scopeLifetimeObservations = scopeLifetimeObservations.filter {
            scopeLifetimes[$0.key] != nil || scopes[$0.key] != nil
        }
    }

    package var cachedScopeCount: Int {
        compactDeadScopes()
        return scopes.count
    }
}
