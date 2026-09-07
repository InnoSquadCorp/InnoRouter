import Foundation
import SwiftUI
import InnoRouter
import AccountFeature
import SearchFeature

@Router(
    deepLinkSchemes: ["app"],
    deepLinkHosts: ["app.example.com"],
    inspectorCatalog: true
)
public enum ComposedAppRoute {
    @FeatureRoute("account.primary")
    case account(AccountRoute)

    @FeatureRoute("search.primary")
    case search(SearchRoute)

    public var destination: some View {
        switch self {
        case .account:
            RouterFeatureHost(ComposedAppRoute.Feature.account) {
                AccountRoot()
            }
        case .search:
            RouterFeatureHost(ComposedAppRoute.Feature.search) {
                SearchRoot()
            }
        }
    }
}

@MainActor
public func exerciseFeatureComposition() async -> RouterState<ComposedAppRoute> {
    let store = ComposedAppRoute.makeRouterStore(
        initialState: .rootStack(path: [.account(.overview)])
    )
    let feature = RouterFeatureScope(
        parent: store.scope(),
        mapping: ComposedAppRoute.Feature.account
    )
    _ = await feature.perform(.push(.profile(userID: "external-consumer")))
    return store.state
}

public func exerciseFeatureDeepLinkOrigins() -> [URL] {
    guard let accountOrigin = DeepLinkOrigin(
        scheme: "account",
        host: "account.example.com"
    ), let searchOrigin = DeepLinkOrigin(
        scheme: "search",
        host: "search.example.com"
    ) else { return [] }
    return [
        ComposedAppRoute.account(.profile(userID: "42")).deepLinkURL(origin: accountOrigin),
        ComposedAppRoute.search(.result(id: "99")).deepLinkURL(origin: searchOrigin),
    ].compactMap { $0 }
}

public struct FeatureWindowIntegrationResult: Sendable {
    public let state: RouterState<ComposedAppRoute>
    public let accountWindowID: UUID
    public let searchWindowID: UUID
    public let modalValue: String?
}

@MainActor
public func exerciseFeatureWindowIntegration() async throws -> FeatureWindowIntegrationResult {
    let accountWindowID = UUID()
    let searchWindowID = UUID()
    let store = ComposedAppRoute.makeRouterStore(initialState: try RouterState(windows: [
        .init(id: accountWindowID, route: .account(.overview)),
        .init(id: searchWindowID, route: .search(.results(query: "swift"))),
    ]))
    let account = RouterFeatureScope(
        parent: store.scope(at: .window(accountWindowID)),
        mapping: ComposedAppRoute.Feature.account
    )
    let search = RouterFeatureScope(
        parent: store.scope(at: .window(searchWindowID)),
        mapping: ComposedAppRoute.Feature.search
    )
    var events = store.events.makeAsyncIterator()
    let presentation = Task { @MainActor in
        await account.present(.profile(userID: "modal"), expecting: String.self)
    }
    while let event = await events.next() {
        if case .committed = event { break }
    }
    _ = await search.perform(.push(.result(id: "42")))
    try await account.finishPresentation(returning: "saved")
    let modalValue: String? = if case .value(let value) = await presentation.value {
        value
    } else {
        nil
    }
    return FeatureWindowIntegrationResult(
        state: store.state,
        accountWindowID: accountWindowID,
        searchWindowID: searchWindowID,
        modalValue: modalValue
    )
}
