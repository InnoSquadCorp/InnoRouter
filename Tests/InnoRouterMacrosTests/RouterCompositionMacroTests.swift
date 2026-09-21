#if canImport(InnoRouterMacrosPlugin)
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Router composition macro tests")
struct RouterCompositionMacroTests {
    @Test("E065 rejects a FeatureRoute declared inside conditional compilation")
    func conditionalFeatureRoute() {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalFeatureRoute {
            #if os(macOS)
                @FeatureRoute
                case conditional(ChildRoute)
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalFeatureRoute {
            #if os(macOS)
                case conditional(ChildRoute)
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E065] @FeatureRoute cases cannot be conditional because the generated composition catalog must be stable",
                    line: 4,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E065 finds a qualified FeatureRoute inside nested conditionals")
    func nestedQualifiedConditionalFeatureRoute() {
        assertMacroExpansion(
            """
            @Router
            enum NestedConditionalFeatureRoute {
            #if os(macOS)
            #if DEBUG
                @InnoRouterMacros.FeatureRoute
                case conditional(ChildRoute)
            #endif
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum NestedConditionalFeatureRoute {
            #if os(macOS)
            #if DEBUG
                @InnoRouterMacros.FeatureRoute
                case conditional(ChildRoute)
            #endif
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E065] @FeatureRoute cases cannot be conditional because the generated composition catalog must be stable",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E065 rejects a conditionally compiled FeatureRoute attribute")
    func conditionalFeatureRouteAttribute() {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalAttributeFeatureRoute {
            #if DEBUG
                @FeatureRoute
            #endif
                case conditional(ChildRoute)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAttributeFeatureRoute {
            #if DEBUG
                @FeatureRoute
            #endif
                case conditional(ChildRoute)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E065] @FeatureRoute cases cannot be conditional because the generated composition catalog must be stable",
                    line: 4,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E065 rejects a mixed direct and conditional FeatureRoute catalog")
    func mixedDirectAndConditionalFeatureRoute() {
        assertMacroExpansion(
            """
            @Router
            enum MixedConditionalFeatureRoute {
                @FeatureRoute
                case account(AccountRoute)
            #if DEBUG
                @FeatureRoute
                case debug(DebugRoute)
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum MixedConditionalFeatureRoute {
                case account(AccountRoute)
            #if DEBUG
                case debug(DebugRoute)
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E065] @FeatureRoute cases cannot be conditional because the generated composition catalog must be stable",
                    line: 6,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

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

    @Test("E067 rejects a manual routerFeatureCatalog")
    func featureCatalogMemberConflict() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @FeatureRoute
                case account(AccountRoute)
                static var routerFeatureCatalog: [String] { [] }
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case account(AccountRoute)
                static var routerFeatureCatalog: [String] { [] }
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E067] @Router with @FeatureRoute generates `routerFeatureCatalog`; remove the manual declaration or feature annotations",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E067 identifies a direct routerFeatureCatalog case conflict")
    func featureCatalogCaseConflict() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @FeatureRoute
                case account(AccountRoute)
                case routerFeatureCatalog
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case account(AccountRoute)
                case routerFeatureCatalog
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E067] @Router with @FeatureRoute generates `routerFeatureCatalog`; remove the manual declaration or feature annotations",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    @Test("A conditional routerFeatureCatalog conflict is left to the compiler")
    func conditionalFeatureCatalogMemberIsCompilerOwned() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @FeatureRoute
                case account(AccountRoute)
            #if DEBUG
                static var routerFeatureCatalog: [String] { [] }
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case account(AccountRoute)
            #if DEBUG
                static var routerFeatureCatalog: [String] { [] }
            #endif
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
                    internal static var account: InnoRouterCore.RouterFeatureMapping<AppRoute, AccountRoute> {
                        .init(
                            id: "account",
                            namespace: "AppRoute.account",
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
                }

                internal static var routerFeatureCatalog: [InnoRouterCore.RouterFeatureCatalogEntry] {
                    [
                        .init(
                            id: "account",
                            namespace: "AppRoute.account",
                            childRouteTypeName: "AccountRoute"
                        )
                    ]
                }
            }
            """,
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

                internal static var routerFeatureCatalog: [InnoRouterCore.RouterFeatureCatalogEntry] {
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
            }
            """,
            macros: makeTestMacros()
        )
    }

    // The duplicate-marker diagnostics used to anchor on `attributes[1]` from
    // inside the `else` of `guard attributes.count == 1` — a branch that also
    // runs for an empty list, so the subscript was an out-of-bounds trap held
    // off only by caller pre-filtering. They now describe the duplicates and
    // offer the removal edit.
    // Only @DeepLink's misplacement diagnostic had a test; the other four
    // markers' `requiresCase` paths were never exercised. Each now asserts the
    // diagnostic and the removal edit.
    @Test("Misplaced @TabItem offers a removal fix-it")
    func misplacedTabItemOffersRemoval() {
        assertMacroExpansion(
            """
            struct Example {
                @TabItem("Home", systemImage: "house")
                var value = 0
            }
            """,
            expandedSource: """
            struct Example {
                var value = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E007] @TabItem can only be attached to an enum case inside an @Router enum",
                    line: 2,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Remove `@TabItem`"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove `@TabItem`"],
            fixedSource: """
            struct Example {
                var value = 0
            }
            """
        )
    }

    @Test("Misplaced @Scene offers a removal fix-it")
    func misplacedSceneOffersRemoval() {
        assertMacroExpansion(
            """
            struct Example {
                @Scene("window")
                var value = 0
            }
            """,
            expandedSource: """
            struct Example {
                var value = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E030] @Scene can only be attached to an enum case inside an @Router enum",
                    line: 2,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Remove `@Scene`"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove `@Scene`"],
            fixedSource: """
            struct Example {
                var value = 0
            }
            """
        )
    }

    @Test("Misplaced @FeatureRoute offers a removal fix-it")
    func misplacedFeatureRouteOffersRemoval() {
        assertMacroExpansion(
            """
            struct Example {
                @FeatureRoute("account")
                var value = 0
            }
            """,
            expandedSource: """
            struct Example {
                var value = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E058] @FeatureRoute can only be attached to an enum case inside an @Router enum",
                    line: 2,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Remove `@FeatureRoute`"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove `@FeatureRoute`"],
            fixedSource: """
            struct Example {
                var value = 0
            }
            """
        )
    }

    @Test("Misplaced @PresentationResult offers a removal fix-it")
    func misplacedPresentationResultOffersRemoval() {
        assertMacroExpansion(
            """
            struct Example {
                @PresentationResult(Int.self)
                var value = 0
            }
            """,
            expandedSource: """
            struct Example {
                var value = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E051] @PresentationResult can only be attached to an enum case",
                    line: 2,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Remove `@PresentationResult`"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove `@PresentationResult`"],
            fixedSource: """
            struct Example {
                var value = 0
            }
            """
        )
    }

    @Test("Redundant RouterTabRoute conformance offers a removal fix-it")
    func redundantRouterTabConformanceFixIt() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute: RouterTabRoute {
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute: RouterTabRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute {
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
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W004] RouterTabRoute conformance is supplied by @Router when @TabItem is present; remove the explicit conformance",
                    line: 2,
                    column: 14,
                    severity: .warning,
                    fixIts: [
                        FixItSpec(message: "Remove the redundant `RouterTabRoute` conformance"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove the redundant `RouterTabRoute` conformance"],
            fixedSource: """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """
        )
    }

    @Test("Duplicate @TabItem offers a removal fix-it")
    func duplicateTabItemFixIt() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house")
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E010] a router tab case must have exactly one @TabItem annotation; remove the duplicate",
                    line: 4,
                    column: 5,
                    severity: .error,
                    fixIts: [
                        FixItSpec(message: "Remove the duplicate `@TabItem`"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove the duplicate `@TabItem`"],
            fixedSource: """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """
        )
    }

    @Test("Duplicate @DeepLink markers on one line remove cleanly")
    func duplicateDeepLinkMarkerFixIt() {
        assertMacroExpansion(
            """
            @Router(deepLinkSchemes: ["app"], deepLinkHosts: ["app.example.com"])
            enum AppRoute {
                @DeepLink("/home") @DeepLink("/home")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {

                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E021] a route case must have exactly one @DeepLink annotation; remove the duplicate",
                    line: 3,
                    column: 24,
                    severity: .error,
                    fixIts: [
                        FixItSpec(message: "Remove the duplicate `@DeepLink`"),
                    ]
                )
            ],
            macros: makeTestMacros(),
            applyFixIts: ["Remove the duplicate `@DeepLink`"],
            fixedSource: """
            @Router(deepLinkSchemes: ["app"], deepLinkHosts: ["app.example.com"])
            enum AppRoute {
                @DeepLink("/home")
                case home
                var destination: some View { EmptyView() }
            }
            """
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

    @Test("Explicit tab IDs generate durable scope identities without changing typed tab identity")
    func explicitTabIDExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house", id: "main")
                case home
                @TabItem("Settings", systemImage: "gear")
                case settings
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case home
                case settings
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
                    case settings

                    internal var title: Foundation.LocalizedStringResource {
                        switch self {
                        case .home:
                            return "Home"
                        case .settings:
                            return "Settings"
                        }
                    }

                    internal var systemImage: Swift.String {
                        switch self {
                        case .home:
                            return "house"
                        case .settings:
                            return "gear"
                        }
                    }

                    internal var routerScopeID: InnoRouterCore.RouterScopeID {
                        switch self {
                        case .home:
                            return InnoRouterCore.RouterScopeID("main")
                        case .settings:
                            return InnoRouterCore.RouterScopeID("settings")
                        }
                    }
                }

                internal static var routerTabs: [InnoRouterSwiftUI.RouterTabDescriptor<Self, Tab>] {
                    [.init(tab: .home, root: .home), .init(tab: .settings, root: .settings)]
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Explicit tab IDs reject collisions with default case-name IDs")
    func duplicateEffectiveTabID() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house", id: "settings")
                case home
                @TabItem("Settings", systemImage: "gear")
                case settings
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case home
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E009] @Router tab scope ID `settings` is duplicated; give every tab a unique effective ID",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Escaped explicit tab IDs are compared by represented value")
    func escapedDuplicateEffectiveTabID() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house", id: "set\\u{74}ings")
                case home
                @TabItem("Settings", systemImage: "gear")
                case settings
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case home
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E009] @Router tab scope ID `settings` is duplicated; give every tab a unique effective ID",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Explicit tab IDs require nonempty noninterpolated literals")
    func invalidExplicitTabID() {
        for invalidLiteral in ["\"\"", "\"   \""] {
            assertMacroExpansion(
                """
                @Router
                enum AppRoute {
                    @TabItem("Home", systemImage: "house", id: \(invalidLiteral))
                    case home
                    var destination: some View { EmptyView() }
                }
                """,
                expandedSource: """
                enum AppRoute {
                    case home
                    @Swift.MainActor @SwiftUI.ViewBuilder
                    var destination: some View { EmptyView() }
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message: "[InnoRouterMacro.E013] @TabItem has invalid native tab metadata: id must be one nonempty noninterpolated string literal",
                        line: 3,
                        column: 5
                    )
                ],
                macros: makeTestMacros()
            )
        }

        assertMacroExpansion(
            """
            let persistedID = "home"
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house", id: persistedID)
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            let persistedID = "home"
            enum AppRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E013] @TabItem has invalid native tab metadata: id must be one nonempty noninterpolated string literal",
                    line: 4,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )

        assertMacroExpansion(
            #"""
            let persistedID = "home"
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house", id: "\(persistedID)")
                case home
                var destination: some View { EmptyView() }
            }
            """#,
            expandedSource: """
            let persistedID = "home"
            enum AppRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E013] @TabItem has invalid native tab metadata: id must be one nonempty noninterpolated string literal",
                    line: 4,
                    column: 5
                )
            ],
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

    @Test("Presentation factories preserve the route case availability")
    func presentationAvailabilityExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum AvailablePresentationRoute {
                @available(macOS 26, *)
                @PresentationResult(Bool.self)
                case future
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AvailablePresentationRoute {
                @available(macOS 26, *)
                case future
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AvailablePresentationRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Presentation {
                    @available(macOS 26, *)
                    internal static var future: InnoRouterCore.RouterPresentationRequest<AvailablePresentationRoute, Bool> {
                        .init(route: .future)
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Presentation functions preserve multiple availability constraints")
    func presentationFunctionAvailabilityExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum MultiAvailablePresentationRoute {
                @available(macOS, introduced: 15, deprecated: 26)
                @available(iOS, introduced: 18, obsoleted: 27)
                @available(tvOS, unavailable)
                @PresentationResult(Bool.self)
                case future(id: String)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum MultiAvailablePresentationRoute {
                @available(macOS, introduced: 15, deprecated: 26)
                @available(iOS, introduced: 18, obsoleted: 27)
                @available(tvOS, unavailable)
                case future(id: String)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension MultiAvailablePresentationRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Presentation {
                    @available(macOS, introduced: 15, deprecated: 26)
                    @available(iOS, introduced: 18, obsoleted: 27)
                    @available(tvOS, unavailable)
                    internal static func future(id: String) -> InnoRouterCore.RouterPresentationRequest<MultiAvailablePresentationRoute, Bool> {
                        .init(route: .future(id: id))
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Presentation factories preserve conditional availability attributes")
    func presentationConditionalAvailabilityExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalPresentationRoute {
                @PresentationResult(Bool.self)
            #if os(macOS)
                @available(macOS 26, *)
            #endif
                case future
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalPresentationRoute {
            #if os(macOS)
                @available(macOS 26, *)
            #endif
                case future
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension ConditionalPresentationRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Presentation {
                    #if os(macOS)
                    @available(macOS 26, *)
                    #endif
                    internal static var future: InnoRouterCore.RouterPresentationRequest<ConditionalPresentationRoute, Bool> {
                        .init(route: .future)
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Presentation functions preserve elseif and nested availability branches")
    func presentationNestedConditionalAvailabilityExpansion() {
        assertMacroExpansion(
            """
            @Router
            enum NestedConditionalPresentationRoute {
                @PresentationResult(Bool.self)
            #if os(macOS)
                @available(macOS 26, *)
            #elseif os(iOS)
            #if DEBUG
                @available(iOS 27, *)
            #else
                @available(iOS, unavailable)
            #endif
            #else
                @available(tvOS, deprecated: 27)
            #endif
                case future(id: String)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum NestedConditionalPresentationRoute {
            #if os(macOS)
                @available(macOS 26, *)
            #elseif os(iOS)
            #if DEBUG
                @available(iOS 27, *)
            #else
                @available(iOS, unavailable)
            #endif
            #else
                @available(tvOS, deprecated: 27)
            #endif
                case future(id: String)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension NestedConditionalPresentationRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Presentation {
                    #if os(macOS)
                    @available(macOS 26, *)
                    #elseif os(iOS)
                    #if DEBUG
                    @available(iOS 27, *)
                    #else
                    @available(iOS, unavailable)
                    #endif
                    #else
                    @available(tvOS, deprecated: 27)
                    #endif
                    internal static func future(id: String) -> InnoRouterCore.RouterPresentationRequest<NestedConditionalPresentationRoute, Bool> {
                        .init(route: .future(id: id))
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Conditional source text mentioning PresentationResult is ignored")
    func presentationTextInsideConditionalCompilation() {
        assertMacroExpansion(
            """
            @Router
            enum PresentationTextRoute {
            #if DEBUG
                static let marker = "@PresentationResult"
            #endif
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum PresentationTextRoute {
            #if DEBUG
                static let marker = "@PresentationResult"
            #endif
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension PresentationTextRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("E055 finds a qualified presentation marker in nested conditional compilation")
    func nestedQualifiedConditionalPresentationResult() {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalPresentationRoute {
            #if os(macOS)
            #if DEBUG
                @InnoRouterMacros.PresentationResult(Bool.self)
                case approval
            #endif
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalPresentationRoute {
            #if os(macOS)
            #if DEBUG
                @InnoRouterMacros.PresentationResult(Bool.self)
                case approval
            #endif
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E055] @PresentationResult cases cannot be declared inside #if",
                    line: 1,
                    column: 1
                ),
            ],
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

    @Test("Presentation factories preserve Self and allocate unique local names")
    func presentationSelfAndBindingCollision() {
        assertMacroExpansion(
            """
            @Router
            indirect enum PresentationEdgeRoute {
                case leaf
                @PresentationResult(Bool.self)
                case edit(value1: Int, Self)
                @PresentationResult(Self.self)
                case recursiveResult
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            indirect enum PresentationEdgeRoute {
                case leaf
                case edit(value1: Int, Self)
                case recursiveResult
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension PresentationEdgeRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Presentation {
                    internal static func edit(value1: Int, _ __innoRouterPresentationValue1: PresentationEdgeRoute) -> InnoRouterCore.RouterPresentationRequest<PresentationEdgeRoute, Bool> {
                        .init(route: .edit(value1: value1, __innoRouterPresentationValue1))
                    }
                    internal static var recursiveResult: InnoRouterCore.RouterPresentationRequest<PresentationEdgeRoute, PresentationEdgeRoute> {
                        .init(route: .recursiveResult)
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Feature and associated-value catalog names remain distinct from route metadata")
    func featureCatalogNameSeparation() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @FeatureRoute
                case catalog(CatalogRoute)
                case routerFeatureCatalog(Int)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case catalog(CatalogRoute)
                case routerFeatureCatalog(Int)
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
                    internal static var catalog: InnoRouterCore.RouterFeatureMapping<AppRoute, CatalogRoute> {
                        .init(
                            id: "catalog",
                            namespace: "AppRoute.catalog",
                            route: .init(
                                embed: { value in
                                    .catalog(value)
                                },
                                extract: { parent in
                                    guard case .catalog(let value) = parent else {
                                        return nil
                                    }
                                    return value
                                }
                            )
                        )
                    }
                }

                internal static var routerFeatureCatalog: [InnoRouterCore.RouterFeatureCatalogEntry] {
                    [
                        .init(
                            id: "catalog",
                            namespace: "AppRoute.catalog",
                            childRouteTypeName: "CatalogRoute"
                        )
                    ]
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Feature Self payloads keep the enclosing route type")
    func featureSelfPayloadUsesParentRoute() {
        assertMacroExpansion(
            """
            @Router
            indirect enum TreeRoute {
                @FeatureRoute
                case child(Self)
                case leaf
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            indirect enum TreeRoute {
                case child(Self)
                case leaf
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension TreeRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal enum Feature {
                    internal static var child: InnoRouterCore.RouterFeatureMapping<TreeRoute, TreeRoute> {
                        .init(
                            id: "child",
                            namespace: "TreeRoute.child",
                            route: .init(
                                embed: { value in
                                    .child(value)
                                },
                                extract: { parent in
                                    guard case .child(let value) = parent else {
                                        return nil
                                    }
                                    return value
                                }
                            )
                        )
                    }
                }

                internal static var routerFeatureCatalog: [InnoRouterCore.RouterFeatureCatalogEntry] {
                    [
                        .init(
                            id: "child",
                            namespace: "TreeRoute.child",
                            childRouteTypeName: "TreeRoute"
                        )
                    ]
                }
            }
            """,
            macros: makeTestMacros()
        )
    }
}
#endif
