// MARK: - RouterMacroTests.swift
// InnoRouter Macros Tests
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Router Macro Tests")
struct RouterMacroTests {
    @Test("Adds view attributes and DestinationRoute conformance")
    func basicExpansion() throws {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                case settings

                var destination: some View {
                    switch self {
                    case .settings:
                        SettingsView()
                    }
                }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder

                var destination: some View {
                    switch self {
                    case .settings:
                        SettingsView()
                    }
                }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute {
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

    @Test("Preserves explicit actor and builder attributes")
    func existingAttributesAreNotDuplicated() throws {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                case settings

                @Swift.MainActor
                @SwiftUI.ViewBuilder
                var destination: some SwiftUI.View {
                    SettingsView()
                }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case settings

                @Swift.MainActor
                @SwiftUI.ViewBuilder
                var destination: some SwiftUI.View {
                    SettingsView()
                }
            }

            extension AppRoute: InnoRouterSwiftUI.DestinationRoute {
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

    @Test("Public enums receive a public destination witness")
    func publicAccessExpansion() throws {
        assertMacroExpansion(
            """
            @Router
            public enum PublicRoute {
                case settings
                private var destination: some View { SettingsView() }
            }
            """,
            expandedSource: """
            public enum PublicRoute {
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                private var destination: some View { SettingsView() }
            }

            extension PublicRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                public static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Non-enum declarations receive the shared actionable diagnostic")
    func rejectsStruct() throws {
        assertMacroExpansion(
            """
            @Router
            struct NotARouter {
            }
            """,
            expandedSource: """
            struct NotARouter {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E001] @Router can only be applied to enum declarations",
                    line: 1,
                    column: 1,
                    fixIts: [FixItSpec(message: "Change `struct` to `enum`")]
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Missing destination property is diagnosed")
    func missingDestination() throws {
        assertMacroExpansion(
            """
            @Router
            enum MissingDestination {
                case settings
            }
            """,
            expandedSource: """
            enum MissingDestination {
                case settings
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E004] @Router requires `var destination: some View { ... }` inside the enum",
                    line: 1,
                    column: 1
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Static destination property is diagnosed")
    func staticDestination() throws {
        assertMacroExpansion(
            """
            @Router
            enum StaticDestination {
                case settings
                static var destination: some View { SettingsView() }
            }
            """,
            expandedSource: """
            enum StaticDestination {
                case settings
                static var destination: some View { SettingsView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E005] @Router cannot use this `destination` property: it must be an instance property, not a static property. Declare an instance computed `var destination: some View { ... }`.",
                    line: 4,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Concrete destination return type is diagnosed")
    func concreteDestinationType() throws {
        assertMacroExpansion(
            """
            @Router
            enum ConcreteDestination {
                case settings
                var destination: Text { Text("Settings") }
            }
            """,
            expandedSource: """
            enum ConcreteDestination {
                case settings
                var destination: Text { Text("Settings") }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E005] @Router cannot use this `destination` property: its return type must be `some View`. Declare an instance computed `var destination: some View { ... }`.",
                    line: 4,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Manual destination function conflict is diagnosed")
    func destinationFunctionConflict() throws {
        assertMacroExpansion(
            """
            @Router
            enum ManualDestination {
                case settings
                var destination: some View { SettingsView() }
                static func destination(for route: Self) -> some View { route.destination }
            }
            """,
            expandedSource: """
            enum ManualDestination {
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { SettingsView() }
                static func destination(for route: Self) -> some View { route.destination }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E006] @Router generates `static destination(for:)`; remove the manual function or remove @Router and conform to DestinationRoute manually",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Generic route spelling of the generated witness is diagnosed")
    func genericDestinationFunctionConflict() throws {
        assertMacroExpansion(
            """
            @Router
            enum GenericDestination<Value: Hashable & Sendable> {
                case detail(Value)
                var destination: some View { DetailView(value: self) }
                static func destination(for route: GenericDestination<Value>) -> some View { route.destination }
            }
            """,
            expandedSource: """
            enum GenericDestination<Value: Hashable & Sendable> {
                case detail(Value)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { DetailView(value: self) }
                static func destination(for route: GenericDestination<Value>) -> some View { route.destination }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E006] @Router generates `static destination(for:)`; remove the manual function or remove @Router and conform to DestinationRoute manually",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Non-conflicting destination overloads remain available")
    func destinationFunctionOverload() throws {
        assertMacroExpansion(
            """
            @Router
            enum StyledDestination {
                case settings
                var destination: some View { SettingsView() }
                static func destination(for style: Int) -> String { "Style \\(style)" }
            }
            """,
            expandedSource: """
            enum StyledDestination {
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { SettingsView() }
                static func destination(for style: Int) -> String { "Style \\(style)" }
            }

            extension StyledDestination: InnoRouterSwiftUI.DestinationRoute {
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

    @Test("Empty route enum remains valid but warns")
    func emptyRouterWarning() throws {
        assertMacroExpansion(
            """
            @Router
            enum RootOnlyRoute {
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum RootOnlyRoute {
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension RootOnlyRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W001] @Router is attached to an enum with no route cases; RouterHost can only render its root view",
                    line: 1,
                    column: 1,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Direct conformance remains buildable but warns")
    func redundantConformanceWarning() throws {
        assertMacroExpansion(
            """
            @Router
            enum RedundantRoute: DestinationRoute {
                case settings
                var destination: some View { SettingsView() }
            }
            """,
            expandedSource: """
            enum RedundantRoute: DestinationRoute {
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { SettingsView() }
            }

            extension RedundantRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W002] DestinationRoute conformance is supplied by @Router; remove the explicit conformance",
                    line: 2,
                    column: 20,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Direct Route conformance remains buildable but warns")
    func redundantRouteConformanceWarning() throws {
        assertMacroExpansion(
            """
            @Router
            enum RedundantRoute: Route {
                case settings
                var destination: some View { SettingsView() }
            }
            """,
            expandedSource: """
            enum RedundantRoute: Route {
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { SettingsView() }
            }

            extension RedundantRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W003] Route conformance is inherited from the DestinationRoute supplied by @Router; remove the explicit conformance",
                    line: 2,
                    column: 20,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Constrained generic routes are supported")
    func constrainedGenericRoute() throws {
        assertMacroExpansion(
            """
            @Router
            enum GenericRoute<Value: Hashable & Sendable> {
                case detail(Value)
                var destination: some View { DetailView(value: self) }
            }
            """,
            expandedSource: """
            enum GenericRoute<Value: Hashable & Sendable> {
                case detail(Value)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { DetailView(value: self) }
            }

            extension GenericRoute: InnoRouterSwiftUI.DestinationRoute {
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
}

#endif
