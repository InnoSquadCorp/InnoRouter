import Foundation
import SwiftUI

import InnoRouter

public struct ExternalShadowedID: Hashable, Sendable, Codable, DeepLinkParameterValue {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var deepLinkParameterString: String { rawValue }

    public static func parseDeepLinkParameter(_ value: String) -> Self? {
        Self(rawValue: value)
    }
}

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"],
    inspectorCatalog: true
)
public indirect enum ExternalRoute: Codable {
    public typealias UUID = ExternalShadowedID

    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    case settings

    @DeepLink("/details/:id")
    case detail(id: String)

    @DeepLink("/shadow/:id")
    case shadowed(id: UUID)

    @available(macOS 26, *)
    @PresentationResult(Bool.self)
    case futureConfirmation

    @PresentationResult(Bool.self)
#if os(macOS)
    @available(macOS 26, *)
#endif
    case conditionalFutureConfirmation

    @PresentationResult(Self.self)
    case edit(value1: Int, Self)

    var destination: some View {
        switch self {
        case .home:
            Text("Home")
        case .settings:
            Text("Settings")
        case .detail(let id):
            Text("Detail \(id)")
        case .shadowed(let id):
            Text("Shadowed \(id.rawValue)")
        case .futureConfirmation:
            Text("Future confirmation")
        case .conditionalFutureConfirmation:
            Text("Conditional future confirmation")
        case .edit(let value1, let route):
            Text("Edit \(value1): \(Swift.String(describing: route))")
        }
    }
}

@Router
public indirect enum ExternalFeatureRoute {
    @FeatureRoute
    case catalog(ExternalRoute)

    case routerFeatureCatalog(Int)

#if INNOROUTER_CONDITIONAL_FEATURE_CATALOG_CONFLICT
    static var routerFeatureCatalog: [String] { [] }
#endif

#if INNOROUTER_NESTED_FEATURE_CATALOG_CONFLICT && os(macOS)
#if INNOROUTER_NESTED_FEATURE_IF
    static var routerFeatureCatalog: [Int] { [] }
#elseif INNOROUTER_NESTED_FEATURE_ELSEIF
    static var routerFeatureCatalog: [Bool] { [] }
#else
    static var routerFeatureCatalog: [Double] { [] }
#endif
#endif

    var routerFeatureCatalog: String { "instance-catalog" }

    var destination: some View {
        switch self {
        case .catalog(let route):
            route.destination
        case .routerFeatureCatalog(let value):
            Text("Catalog overload \(value)")
        }
    }
}

public enum ExternalFeatureNamespace {
    @Router
    public indirect enum Tree<Value: Hashable & Sendable> {
        @FeatureRoute
        case child(Self)

        case leaf(Value)

        public var destination: some View {
            switch self {
            case .child:
                Text("Recursive child")
            case .leaf(let value):
                Text("Leaf \(String(describing: value))")
            }
        }
    }
}

#if INNOROUTER_FEATURE_CASE_CONFLICT
@Router
private enum ExternalFeatureCaseConflictRoute {
    @FeatureRoute
    case child(ExternalRoute)

    case routerFeatureCatalog

    var destination: some View { EmptyView() }
}
#endif

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["shadow-string.example.com"],
    inspectorCatalog: true
)
public enum ExternalStringShadowRoute {
    public typealias String = ExternalShadowedID

    @DeepLink("/items/:id")
    case item(id: String)

    var destination: some View {
        switch self {
        case .item(let id):
            Text("Shadowed string \(id.rawValue)")
        }
    }
}

@Routable
public indirect enum ExternalConditionalRoute {
#if INNOROUTER_CUSTOM_CONDITIONAL
    case custom(id: String)
#elseif os(macOS)
    case desktop(id: String)
#else
    case portable(id: String)
#endif

#if canImport(Foundation)
#if arch(arm64)
    case nativeFoundation
#endif
#endif

    case bindingCollision(Int, v0: String)
    case recursive(Self)

#if os(macOS)
    @available(macOS 26.0, *)
#endif
    case future
}

private struct ExternalActions: View {
    @EnvironmentRouter(ExternalRoute.self) private var router

    var body: some View {
        Button("Route") {
            router.go(.detail(id: "42"))
            router.sheet(.settings)
            router.dismiss()
            router.back()
        }
    }
}

@MainActor
private final class ExternalSession {
    var isAuthenticated = false
}

@MainActor
public enum MacroFirstConsumerProbe {
    public static func exercise() async throws {
        _ = RouterHost(ExternalRoute.self) {
            ExternalActions()
        }.body

#if !os(watchOS)
        _ = RouterSplitHost(ExternalRoute.self) {
            Text("Sidebar")
        } root: {
            ExternalActions()
        }.body
#endif

        _ = RouterTabHost(ExternalRoute.self, initial: .home).body

        let store = ExternalRoute.makeRouterStore()
        _ = await store.perform(.push(.detail(id: "42")))
        _ = await store.perform(.present(.init(route: .settings, style: .sheet)))
        _ = await store.perform(.dismissPresentation)

#if INNOROUTER_CUSTOM_CONDITIONAL
        let conditional = ExternalConditionalRoute.Cases.custom.embed("custom")
        precondition(ExternalConditionalRoute.Cases.custom.extract(conditional) == "custom")
#elseif os(macOS)
        let conditional = ExternalConditionalRoute.Cases.desktop.embed("desktop")
        precondition(ExternalConditionalRoute.Cases.desktop.extract(conditional) == "desktop")
#else
        let conditional = ExternalConditionalRoute.Cases.portable.embed("portable")
        precondition(ExternalConditionalRoute.Cases.portable.extract(conditional) == "portable")
#endif

#if canImport(Foundation) && arch(arm64)
        _ = ExternalConditionalRoute.Cases.nativeFoundation.embed(())
#endif

        let collision = ExternalConditionalRoute.Cases.bindingCollision.embed((1, "one"))
        precondition(
            ExternalConditionalRoute.Cases.bindingCollision.extract(collision)?.1 == "one"
        )
        let recursive = ExternalConditionalRoute.Cases.recursive.embed(conditional)
        precondition(ExternalConditionalRoute.Cases.recursive.extract(recursive) != nil)

#if os(macOS)
        if #available(macOS 26.0, *) {
            _ = ExternalConditionalRoute.Cases.future.embed(())
        }
#else
        _ = ExternalConditionalRoute.Cases.future.embed(())
#endif

        if #available(macOS 26, *) {
            _ = ExternalRoute.Presentation.futureConfirmation
            _ = ExternalRoute.Presentation.conditionalFutureConfirmation
        }

        let edit: RouterPresentationRequest<ExternalRoute, ExternalRoute> =
            ExternalRoute.Presentation.edit(value1: 7, .home)
        precondition(edit.route == .edit(value1: 7, .home))

        precondition(ExternalFeatureRoute.Feature.catalog.id == "catalog")
        precondition(ExternalFeatureRoute.routerFeatureCatalog.map(\.id) == ["catalog"])
        precondition(
            ExternalFeatureRoute.catalog(.home).routerFeatureCatalog == "instance-catalog"
        )
        precondition(
            ExternalFeatureRoute.routerFeatureCatalog(7) == .routerFeatureCatalog(7)
        )

        typealias RecursiveFeature = ExternalFeatureNamespace.Tree<String>
        let recursiveLeaf = RecursiveFeature.leaf("leaf")
        let recursiveParent = RecursiveFeature.Feature.child.route.embed(recursiveLeaf)
        precondition(recursiveParent == .child(.leaf("leaf")))
        precondition(
            RecursiveFeature.Feature.child.route.extract(recursiveParent) == recursiveLeaf
        )
        precondition(RecursiveFeature.routerFeatureCatalog.map(\.id) == ["child"])

        let codec = try RouterSnapshotCodec<ExternalRoute>(currentVersion: 1)
        let data = try await store.snapshot(using: codec)
        _ = try await store.restore(from: data, using: codec)

        if let url = URL(string: "innorouter://app.example.com/details/42") {
            let _: ExternalRoute? = ExternalRoute.resolveDeepLink(url)

            let session = ExternalSession()
            let authenticatedPipeline = RouterLinkPipeline<ExternalRoute>(
                originPolicy: .allowlisted(
                    schemes: ["innorouter"],
                    hosts: ["app.example.com"]
                ),
                customResolver: { _ in
                    RouterPlan(state: .rootStack(path: [.detail(id: "42")]))
                },
                authenticationPolicy: .required(
                    shouldRequireAuthentication: { route in
                        if case .detail = route { return true }
                        return false
                    },
                    isAuthenticated: { await session.isAuthenticated }
                )
            )
            _ = await authenticatedPipeline.decide(for: url)
        }
    }
}
