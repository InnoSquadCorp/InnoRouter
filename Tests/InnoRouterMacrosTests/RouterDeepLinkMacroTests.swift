// MARK: - RouterDeepLinkMacroTests.swift
// InnoRouter Macros Tests - @Router + @DeepLink
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import Foundation
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Router Deep-Link Macro Tests")
struct RouterDeepLinkExpansionMacroTests {
    @Test("Generates a public typed resolver and normalizes origin allowlists")
    func basicPublicExpansion() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["InnoRouter", "HTTPS"],
                deepLinkHosts: ["App.Example.COM"]
            )
            public enum AppRoute {
                @DeepLink("/products/:id/:featured")
                case product(id: Foundation.UUID, featured: Swift.Bool, page: Swift.Int?)

                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            public enum AppRoute {
                case product(id: Foundation.UUID, featured: Swift.Bool, page: Swift.Int?)
                @Swift.MainActor @SwiftUI.ViewBuilder

                var destination: some View { EmptyView() }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute, InnoRouterDeepLink.DeepLinkRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                public static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                public static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
                    let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
                        configuration: .init(diagnosticsMode: .disabled)
                    ) {
                        InnoRouterDeepLink.DeepLinkMapping("/products/:id/:featured") { parameters in
                            guard let deepLinkValue0 = parameters.firstValue(
                                forName: "id",
                                as: Foundation.UUID.self
                            ) else {
                                return nil
                            }
                            guard let deepLinkValue1 = parameters.firstValue(
                                forName: "featured",
                                as: Swift.Bool.self
                            ) else {
                                return nil
                            }
                            let deepLinkValue2: Swift.Int?
                            if parameters.firstValue(forName: "page") != nil {
                                guard let parsedDeepLinkValue2 = parameters.firstValue(
                                    forName: "page",
                                    as: Swift.Int.self
                                ) else {
                                    return nil
                                }
                                deepLinkValue2 = parsedDeepLinkValue2
                            } else {
                                deepLinkValue2 = nil
                            }
                            return .product(id: deepLinkValue0, featured: deepLinkValue1, page: deepLinkValue2)
                        }
                    }
                    let pipeline = InnoRouterDeepLink.DeepLinkPipeline<Self>(
                        originPolicy: .allowlisted(
                            schemes: ["innorouter", "https"],
                            hosts: ["app.example.com"]
                        ),
                        matcher: matcher
                    )
                    guard case .plan(let plan) = pipeline.decide(for: url),
                          plan.commands.count == 1,
                          case .push(let route) = plan.commands[0] else {
                        return nil
                    }
                    return route
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("W012 permits ordered fallbacks when typed conversions differ")
    func typedFallbackExpansion() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum TypedFallbackRoute {
                @DeepLink("/items/:value")
                case paged(value: Foundation.UUID, page: Swift.Int?)
                @DeepLink("/items/:value")
                case identifier(value: Foundation.UUID)
                @DeepLink("/items/:value")
                case name(value: Swift.String)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum TypedFallbackRoute {
                case paged(value: Foundation.UUID, page: Swift.Int?)
                case identifier(value: Foundation.UUID)
                case name(value: Swift.String)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension TypedFallbackRoute: InnoRouterSwiftUI.DestinationRoute, InnoRouterDeepLink.DeepLinkRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
                    let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
                        configuration: .init(diagnosticsMode: .disabled)
                    ) {
                        InnoRouterDeepLink.DeepLinkMapping("/items/:value") { parameters in
                            guard let deepLinkValue0 = parameters.firstValue(
                                forName: "value",
                                as: Foundation.UUID.self
                            ) else {
                                return nil
                            }
                            let deepLinkValue1: Swift.Int?
                            if parameters.firstValue(forName: "page") != nil {
                                guard let parsedDeepLinkValue1 = parameters.firstValue(
                                    forName: "page",
                                    as: Swift.Int.self
                                ) else {
                                    return nil
                                }
                                deepLinkValue1 = parsedDeepLinkValue1
                            } else {
                                deepLinkValue1 = nil
                            }
                            return .paged(value: deepLinkValue0, page: deepLinkValue1)
                        }
                        InnoRouterDeepLink.DeepLinkMapping("/items/:value") { parameters in
                            guard let deepLinkValue0 = parameters.firstValue(
                                forName: "value",
                                as: Foundation.UUID.self
                            ) else {
                                return nil
                            }
                            return .identifier(value: deepLinkValue0)
                        }
                        InnoRouterDeepLink.DeepLinkMapping("/items/:value") { parameters in
                            guard let deepLinkValue0 = parameters.firstValue(
                                forName: "value",
                                as: Swift.String.self
                            ) else {
                                return nil
                            }
                            return .name(value: deepLinkValue0)
                        }
                    }
                    let pipeline = InnoRouterDeepLink.DeepLinkPipeline<Self>(
                        originPolicy: .allowlisted(
                            schemes: ["innorouter"],
                            hosts: ["app.example.com"]
                        ),
                        matcher: matcher
                    )
                    guard case .plan(let plan) = pipeline.decide(for: url),
                          plan.commands.count == 1,
                          case .push(let route) = plan.commands[0] else {
                        return nil
                    }
                    return route
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W012] @DeepLink mappings overlap: `/items/:param` also matches 1 preceding mapping; declaration order is used, and this mapping is attempted only after all preceding typed conversions return nil",
                    line: 8,
                    column: 5,
                    severity: .warning,
                    notes: [
                        NoteSpec(
                            message: "A preceding overlapping mapping is declared here.",
                            line: 6,
                            column: 5
                        )
                    ]
                ),
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W012] @DeepLink mappings overlap: `/items/:param` also matches 2 preceding mappings; declaration order is used, and this mapping is attempted only after all preceding typed conversions return nil",
                    line: 10,
                    column: 5,
                    severity: .warning,
                    notes: [
                        NoteSpec(
                            message: "A preceding overlapping mapping is declared here.",
                            line: 6,
                            column: 5
                        ),
                        NoteSpec(
                            message: "A preceding overlapping mapping is declared here.",
                            line: 8,
                            column: 5
                        )
                    ]
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Preserves generic payload types and constraints")
    func genericExpansion() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum GenericRoute<Value: Hashable & Sendable & DeepLinkParameterValue> {
                @DeepLink("/values/:value")
                case value(value: Value)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum GenericRoute<Value: Hashable & Sendable & DeepLinkParameterValue> {
                case value(value: Value)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension GenericRoute: InnoRouterSwiftUI.DestinationRoute, InnoRouterDeepLink.DeepLinkRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
                    let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
                        configuration: .init(diagnosticsMode: .disabled)
                    ) {
                        InnoRouterDeepLink.DeepLinkMapping("/values/:value") { parameters in
                            guard let deepLinkValue0 = parameters.firstValue(
                                forName: "value",
                                as: Value.self
                            ) else {
                                return nil
                            }
                            return .value(value: deepLinkValue0)
                        }
                    }
                    let pipeline = InnoRouterDeepLink.DeepLinkPipeline<Self>(
                        originPolicy: .allowlisted(
                            schemes: ["innorouter"],
                            hosts: ["app.example.com"]
                        ),
                        matcher: matcher
                    )
                    guard case .plan(let plan) = pipeline.decide(for: url),
                          plan.commands.count == 1,
                          case .push(let route) = plan.commands[0] else {
                        return nil
                    }
                    return route
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Tab metadata and deep-link resolution coexist in one router extension")
    func tabCoexistence() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum AppTab {
                @TabItem("Home", systemImage: "house")
                @DeepLink("/home")
                case home

                @TabItem("Settings", systemImage: "gear")
                case settings

                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppTab {
                case home
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder

                var destination: some View { EmptyView() }
            }

            extension AppTab: InnoRouterSwiftUI.DestinationRoute, InnoRouterSwiftUI.RouterTab, InnoRouterDeepLink.DeepLinkRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal static var allCases: [Self] {
                    [.home, .settings]
                }

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

                internal static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
                    let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
                        configuration: .init(diagnosticsMode: .disabled)
                    ) {
                        InnoRouterDeepLink.DeepLinkMapping("/home") { parameters in
                            return .home
                        }
                    }
                    let pipeline = InnoRouterDeepLink.DeepLinkPipeline<Self>(
                        originPolicy: .allowlisted(
                            schemes: ["innorouter"],
                            hosts: ["app.example.com"]
                        ),
                        matcher: matcher
                    )
                    guard case .plan(let plan) = pipeline.decide(for: url),
                          plan.commands.count == 1,
                          case .push(let route) = plan.commands[0] else {
                        return nil
                    }
                    return route
                }
            }
            """,
            macros: makeTestMacros()
        )
    }
}

@Suite("Router Deep-Link Diagnostic Tests")
struct RouterDeepLinkDiagnosticMacroTests {
    @Test("E017 rejects @DeepLink outside an enum case")
    func wrongAttachment() throws {
        assertMacroExpansion(
            """
            struct Example {
                @DeepLink("/home")
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
                    message: "[InnoRouterMacro.E017] @DeepLink can only be attached to an enum case inside an @Router enum",
                    line: 2,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E018 rejects a case outside the nearest @Router enum")
    func missingRouter() throws {
        assertMacroExpansion(
            """
            enum PlainRoute {
                @DeepLink("/home")
                case home
            }
            """,
            expandedSource: """
            enum PlainRoute {
                case home
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E018] @DeepLink requires the nearest enclosing enum to use @Router",
                    line: 2,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "E019 rejects nonliteral, duplicate, and malformed allowlists",
        arguments: [
            (
                "@Router(deepLinkSchemes: schemes, deepLinkHosts: [\"app.example.com\"])",
                "`deepLinkSchemes` must be an array of plain string literals"
            ),
            (
                "@Router(deepLinkSchemes: [\"HTTPS\", \"https\"], deepLinkHosts: [\"app.example.com\"])",
                "deepLinkSchemes contains a duplicate after case normalization"
            ),
            (
                "@Router(deepLinkSchemes: [\"1bad\"], deepLinkHosts: [\"app.example.com\"])",
                "`1bad` is not an RFC-compatible URL scheme"
            ),
            (
                "@Router(deepLinkSchemes: [\"https\"], deepLinkHosts: [\"https://app.example.com\"])",
                "`https://app.example.com` is not an exact ASCII DNS, IPv4, or localhost host"
            ),
        ]
    )
    func invalidAllowlist(routerAttribute: String, reason: String) throws {
        assertMacroExpansion(
            """
            \(routerAttribute)
            enum InvalidOriginRoute {
                @DeepLink("/home")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum InvalidOriginRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E019] @Router deep-link allowlists are invalid: \(reason)",
                    line: 1,
                    column: 1
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E020 requires both nonempty allowlists")
    func missingAllowlist() throws {
        assertMacroExpansion(
            """
            @Router(deepLinkSchemes: ["innorouter"])
            enum MissingHostRoute {
                @DeepLink("/home")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum MissingHostRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E020] @DeepLink requires nonempty literal deepLinkSchemes and deepLinkHosts allowlists on @Router",
                    line: 1,
                    column: 1
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E021 rejects duplicate markers")
    func duplicateMarker() throws {
        assertMacroExpansion(
            validRouterSource(
                cases: """
                @DeepLink("/home")
                @DeepLink("/start")
                case home
                """
            ),
            expandedSource: """
            enum InvalidRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E021] a route case must have exactly one @DeepLink annotation; remove the duplicate",
                    line: 7,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E022 requires one marked case per declaration")
    func multipleCasesPerDeclaration() throws {
        assertMacroExpansion(
            validRouterSource(
                cases: """
                @DeepLink("/home")
                case home, settings
                """
            ),
            expandedSource: """
            enum InvalidRoute {
                case home, settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E022] @DeepLink requires one case per declaration; split joined enum cases into separate declarations",
                    line: 6,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "E023 rejects nonliteral and noncanonical patterns",
        arguments: [
            ("@DeepLink(path)", "provide one nonempty plain string literal"),
            ("@DeepLink(\"home\")", "start the path with `/`"),
            ("@DeepLink(\"/home/\")", "omit the trailing slash"),
            ("@DeepLink(\"/home//detail\")", "empty path segments are not allowed"),
            ("@DeepLink(\"/home?tab=1\")", "query and fragment syntax are not part of a path pattern"),
            ("@DeepLink(\"/café\")", "literal segments may contain only URL-unreserved ASCII characters"),
        ]
    )
    func invalidPattern(attribute: String, reason: String) throws {
        assertMacroExpansion(
            validRouterSource(
                cases: """
                \(attribute)
                case home
                """
            ),
            expandedSource: """
            enum InvalidRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E023] @DeepLink pattern is invalid: \(reason)",
                    line: 6,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E024 rejects availability-scoped mappings")
    func unavailableCase() throws {
        assertMacroExpansion(
            validRouterSource(
                cases: """
                @available(iOS 18, *)
                @DeepLink("/home")
                case home
                """
            ),
            expandedSource: """
            enum InvalidRoute {
                @available(iOS 18, *)
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E024] deep-link case `home` cannot be conditionally available",
                    line: 6,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E025 rejects mappings inside conditional compilation")
    func conditionalCase() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum ConditionalRoute {
            #if DEBUG
                @DeepLink("/debug")
                case debug
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalRoute {
            #if DEBUG
                case debug
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E025] @DeepLink cases cannot be declared inside #if; keep the mapping set stable",
                    line: 7,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E025 rejects a conditionally compiled @DeepLink attribute")
    func conditionalAttribute() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum ConditionalAttributeRoute {
            #if DEBUG
                @DeepLink("/debug")
            #endif
                case debug
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAttributeRoute {
            #if DEBUG
                @DeepLink("/debug")
            #endif
                case debug
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E025] @DeepLink cases cannot be declared inside #if; keep the mapping set stable",
                    line: 7,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E024 rejects a conditionally compiled availability attribute")
    func conditionalAvailabilityAttribute() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum ConditionalAvailabilityRoute {
                @DeepLink("/home")
            #if DEBUG
                @available(macOS 14, *)
            #endif
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAvailabilityRoute {
            #if DEBUG
                @available(macOS 14, *)
            #endif
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E024] deep-link case `home` cannot be conditionally available",
                    line: 6,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "E026 rejects unlabeled and structurally unsupported payloads",
        arguments: [
            ("case detail(String)", "every value needs an explicit external label"),
            (
                "case detail(values: [String])",
                "`[String]` must be a nominal DeepLinkParameterValue or Optional of one"
            ),
        ]
    )
    func invalidAssociatedValue(caseDeclaration: String, reason: String) throws {
        assertMacroExpansion(
            validRouterSource(
                cases: """
                @DeepLink("/detail")
                \(caseDeclaration)
                """
            ),
            expandedSource: """
            enum InvalidRoute {
                \(caseDeclaration)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E026] @DeepLink associated value is unsupported: \(reason)",
                    line: 7,
                    column: 17
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "E027 requires an exact required path-payload mapping",
        arguments: [
            (
                "@DeepLink(\"/items/:id\")",
                "case item(slug: String)",
                "placeholder `:id` has no case value with label `id`"
            ),
            (
                "@DeepLink(\"/items\")",
                "case item(id: String)",
                "required value `id` must appear as a path placeholder"
            ),
        ]
    )
    func payloadMismatch(attribute: String, caseDeclaration: String, reason: String) throws {
        assertMacroExpansion(
            validRouterSource(
                cases: """
                \(attribute)
                \(caseDeclaration)
                """
            ),
            expandedSource: """
            enum InvalidRoute {
                \(caseDeclaration)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E027] @DeepLink pattern and case payload do not match: \(reason)",
                    line: 6,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "E028 rejects mappings covered by an earlier generated handler",
        arguments: [
            (
                """
                @DeepLink("/items/:id")
                case item(id: String)
                @DeepLink("/items/:slug")
                case duplicate(slug: String)
                """,
                "`/items/:param` duplicates mapping 1"
            ),
            (
                """
                @DeepLink("/items/:value")
                case text(value: String)
                @DeepLink("/items/:value")
                case identifier(value: Foundation.UUID)
                """,
                "`/items/:param` is fully handled by mapping 1, whose generated typed conversion accepts every value this mapping accepts"
            ),
            (
                """
                @DeepLink("/items/:value")
                case number(value: Int)
                @DeepLink("/items/:value")
                case qualifiedNumber(value: Swift.Int)
                """,
                "`/items/:param` duplicates mapping 1"
            ),
            (
                """
                @DeepLink("/items/:value")
                case identifier(value: UUID)
                @DeepLink("/items/:value")
                case qualifiedIdentifier(value: Foundation.UUID)
                """,
                "`/items/:param` duplicates mapping 1"
            ),
            (
                """
                @DeepLink("/items/:id")
                case base(id: Foundation.UUID)
                @DeepLink("/items/:id")
                case paged(id: Foundation.UUID, page: Swift.Int?)
                """,
                "`/items/:param` is fully handled by mapping 1, whose generated typed conversion accepts every value this mapping accepts"
            ),
        ]
    )
    func unreachablePattern(cases: String, reason: String) throws {
        let declarations = cases
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("@DeepLink") }
            .map { "    " + $0 }
            .joined(separator: "\n")
        assertMacroExpansion(
            validRouterSource(cases: cases),
            expandedSource: """
            enum InvalidRoute {
            \(declarations)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E028] @DeepLink mapping is unreachable: \(reason)",
                    line: 8,
                    column: 5,
                    notes: [
                        NoteSpec(
                            message: "The earlier mapping that takes precedence is declared here.",
                            line: 6,
                            column: 5
                        )
                    ]
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E029 rejects a manual static resolver")
    func conflictingResolver() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum ManualRoute {
                @DeepLink("/home")
                case home
                static func resolveDeepLink(_ url: Foundation.URL) -> Self? { nil }
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ManualRoute {
                case home
                static func resolveDeepLink(_ url: Foundation.URL) -> Self? { nil }
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E029] @Router with @DeepLink generates `resolveDeepLink(_:)`; remove the manual static resolver",
                    line: 8,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("E029 rejects a conditional manual static resolver")
    func conditionalConflictingResolver() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum ManualRoute {
                @DeepLink("/home")
                case home
            #if DEBUG
                static func resolveDeepLink(_ url: Foundation.URL) -> Self? { nil }
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ManualRoute {
                case home
            #if DEBUG
                static func resolveDeepLink(_ url: Foundation.URL) -> Self? { nil }
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E029] @Router with @DeepLink generates `resolveDeepLink(_:)`; remove the manual static resolver",
                    line: 9,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("W006 warns when allowlists have no marked cases")
    func unusedAllowlist() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum PlainRoute {
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum PlainRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension PlainRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W006] deep-link allowlists have no effect because this @Router has no @DeepLink cases",
                    line: 1,
                    column: 1,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("W007 warns for explicit DeepLinkRoute conformance")
    func redundantConformance() throws {
        assertMacroExpansion(
            """
            @Router(
                deepLinkSchemes: ["innorouter"],
                deepLinkHosts: ["app.example.com"]
            )
            enum RedundantRoute: DeepLinkRoute {
                @DeepLink("/home")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum RedundantRoute: DeepLinkRoute {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension RedundantRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
                    let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
                        configuration: .init(diagnosticsMode: .disabled)
                    ) {
                        InnoRouterDeepLink.DeepLinkMapping("/home") { parameters in
                            return .home
                        }
                    }
                    let pipeline = InnoRouterDeepLink.DeepLinkPipeline<Self>(
                        originPolicy: .allowlisted(
                            schemes: ["innorouter"],
                            hosts: ["app.example.com"]
                        ),
                        matcher: matcher
                    )
                    guard case .plan(let plan) = pipeline.decide(for: url),
                          plan.commands.count == 1,
                          case .push(let route) = plan.commands[0] else {
                        return nil
                    }
                    return route
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W007] DeepLinkRoute conformance is supplied by @Router when @DeepLink is present; remove the explicit conformance",
                    line: 5,
                    column: 20,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }

    private func validRouterSource(cases: String) -> String {
        let indentedCases = cases
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
        return """
        @Router(
            deepLinkSchemes: ["innorouter"],
            deepLinkHosts: ["app.example.com"]
        )
        enum InvalidRoute {
        \(indentedCases)
            var destination: some View { EmptyView() }
        }
        """
    }
}

#endif
