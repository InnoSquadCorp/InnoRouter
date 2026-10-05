import InnoRouterCore

@MainActor
extension RouterScope {
    func rebased<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) -> RouterAuthority<R>? {
        guard let owner = owner as? RouterScope<R>,
              let store, store === owner.store,
              path == owner.path, matchesCurrentLifetime, owner.matchesCurrentLifetime else { return nil }
        return replacement as? RouterAuthority<R>
    }
}

@MainActor
extension RouterFeatureScope {
    func rebased<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) -> RouterAuthority<Child>? {
        guard let rebased = parent.rebased(replacing: owner, with: replacement) else { return nil }
        let feature = RouterFeatureScope(parent: rebased.base, mapping: mapping)
        return RouterAuthority(base: feature,
                               enclosingPresentation: rebased.enclosingPresentation?.projected(using: mapping))
    }
}
