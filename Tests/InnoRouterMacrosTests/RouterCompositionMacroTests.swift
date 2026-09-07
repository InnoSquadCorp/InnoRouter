#if canImport(InnoRouterMacrosPlugin)
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Router composition macro tests")
struct RouterCompositionMacroTests {
    @Test("Feature marker rejects a route without one child payload")
    func invalidFeaturePayload() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @FeatureRoute
                case account
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case account
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E062] feature case `account` must carry exactly one associated route value",
                    line: 4,
                    column: 10
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Feature markers generate typed cross-module mappings")
    func featureExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @FeatureRoute("account.primary")
                case account(AccountRoute)
                @FeatureRoute
                case search(route: SearchRoute)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case account(AccountRoute)
                case search(route: SearchRoute)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Feature {
                    internal static var catalog: [InnoRouterCore.RouterFeatureCatalogEntry] {
                        [
                            .init(
                                id: "account.primary",
                                namespace: "AppRoute.account.primary",
                                childRouteTypeName: "AccountRoute"
                            ),
                            .init(
                                id: "search",
                                namespace: "AppRoute.search",
                                childRouteTypeName: "SearchRoute"
                            )
                        ]
                    }

                    internal static var account: InnoRouterCore.RouterFeatureMapping<AppRoute, AccountRoute> {
                        .init(
                            id: "account.primary",
                            namespace: "AppRoute.account.primary",
                            route: .init(
                                embed: { value in
                                    .account(value)
                                },
                                extract: { parent in
                                    guard case .account(let value) = parent else {
                                        return nil
                                    }
                                    return value
                                }
                            )
                        )
                    }

                    internal static var search: InnoRouterCore.RouterFeatureMapping<AppRoute, SearchRoute> {
                        .init(
                            id: "search",
                            namespace: "AppRoute.search",
                            route: .init(
                                embed: { value in
                                    .search(route: value)
                                },
                                extract: { parent in
                                    guard case .search(let value) = parent else {
                                        return nil
                                    }
                                    return value
                                }
                            )
                        )
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Tab markers generate a separate stable tab identity")
    func tabExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house")
                case home
                case detail(id: String)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case home
                case detail(id: String)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute, InnoRouterSwiftUI.RouterTabRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Tab: Swift.String, InnoRouterSwiftUI.RouterTab {
                    case home

                    internal var title: Foundation.LocalizedStringResource {
                        switch self {
                        case .home:
                            return "Home"
                        }
                    }

                    internal var systemImage: Swift.String {
                        switch self {
                        case .home:
                            return "house"
                        }
                    }

                    internal var routerScopeID: InnoRouterCore.RouterScopeID {
                        InnoRouterCore.RouterScopeID(rawValue)
                    }
                }

                internal static var routerTabs: [InnoRouterSwiftUI.RouterTabDescriptor<Self, Tab>] {
                    [.init(tab: .home, root: .home)]
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Scene and typed presentation markers compose in one router")
    func sceneAndPresentationExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @Scene(.window, id: "editor")
                case editor
                @PresentationResult(Bool.self)
                case login
                @PresentationResult(EditorResult.self)
                case edit(id: String)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case editor
                case login
                case edit(id: String)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute, InnoRouterSwiftUI.RouterSceneRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Scene {
                    internal static var editor: InnoRouterSwiftUI.RouterWindowRequest<AppRoute> {
                        .init(route: .editor, sceneID: "editor")
                    }
                }

                internal static var routerScenes: [InnoRouterSwiftUI.RouterSceneDescriptor<Self>] {
                    [
                        .init(route: .editor, id: "editor", style: .window)
                    ]
                }

                internal enum Presentation {
                    internal static var login: InnoRouterCore.RouterPresentationRequest<AppRoute, Bool> {
                        .init(route: .login)
                    }
                    internal static func edit(id: String) -> InnoRouterCore.RouterPresentationRequest<AppRoute, EditorResult> {
                        .init(route: .edit(id: id))
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("E035 rejects a scene catalog declared only inside conditional compilation")
    func conditionalOnlyScene() {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalSceneRoute {
            #if DEBUG
                @Scene(.window)
                case debug
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalSceneRoute {
            #if DEBUG
                case debug
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E035] @Scene cases and attributes cannot be declared inside #if; keep the scene catalog stable across builds",
                    line: 4,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Conditional source text mentioning @Scene does not create a false diagnostic")
    func sceneTextInsideConditionalCompilation() {
        assertMacroExpansion(
            """
            @Router
            enum SceneTextRoute {
                @Scene(.window)
                case editor
            #if DEBUG
                static let marker = "@Scene"
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum SceneTextRoute {
                case editor
            #if DEBUG
                static let marker = "@Scene"
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension SceneTextRoute: InnoRouterSwiftUI.DestinationRoute, InnoRouterSwiftUI.RouterSceneRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Scene {
                    internal static var editor: InnoRouterSwiftUI.RouterWindowRequest<SceneTextRoute> {
                        .init(route: .editor, sceneID: "editor")
                    }
                }

                internal static var routerScenes: [InnoRouterSwiftUI.RouterSceneDescriptor<Self>] {
                    [
                        .init(route: .editor, id: "editor", style: .window)
                    ]
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("E035 rejects a conditionally compiled scene attribute")
    func conditionalSceneAttribute() {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalAttributeSceneRoute {
            #if DEBUG
                @Scene(.window)
            #endif
                case debug
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAttributeSceneRoute {
            #if DEBUG
                @Scene(.window)
            #endif
                case debug
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E035] @Scene cases and attributes cannot be declared inside #if; keep the scene catalog stable across builds",
                    line: 4,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E035 finds a qualified scene marker inside nested conditional compilation")
    func nestedQualifiedConditionalScene() {
        assertMacroExpansion(
            """
            @Router
            enum NestedConditionalSceneRoute {
            #if os(macOS)
            #if DEBUG
                @InnoRouterMacros.Scene(.window)
                case debug
            #endif
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum NestedConditionalSceneRoute {
            #if os(macOS)
            #if DEBUG
                @InnoRouterMacros.Scene(.window)
                case debug
            #endif
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E035] @Scene cases and attributes cannot be declared inside #if; keep the scene catalog stable across builds",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E035 rejects a mixed direct and conditional scene catalog")
    func mixedDirectAndConditionalScene() {
        assertMacroExpansion(
            """
            @Router
            enum MixedConditionalSceneRoute {
                @Scene(.window)
                case editor
            #if DEBUG
                @Scene(.window)
                case debug
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum MixedConditionalSceneRoute {
                case editor
            #if DEBUG
                case debug
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E035] @Scene cases and attributes cannot be declared inside #if; keep the scene catalog stable across builds",
                    line: 6,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }
}
#endif
