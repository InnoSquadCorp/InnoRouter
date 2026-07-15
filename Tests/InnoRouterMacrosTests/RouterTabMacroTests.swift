// MARK: - RouterTabMacroTests.swift
// InnoRouter Macros Tests - @Router + @TabItem
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Router Tab Macro Tests")
struct RouterTabMacroTests {
    @Test("Generates RouterTab metadata for every marked case")
    func basicExpansion() throws {
        assertMacroExpansion(
            """
            @Router
            public enum AppTab {
                @TabItem("Home", systemImage: "house")
                case home

                @TabItem("Settings", systemImage: "gear")
                case settings

                var destination: some View {
                    EmptyView()
                }
            }
            """,
            expandedSource: """
            public enum AppTab {
                case home
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder

                var destination: some View {
                    EmptyView()
                }
            }

            extension AppTab: InnoRouterSwiftUI.DestinationRoute, InnoRouterSwiftUI.RouterTab {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                public static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                public static var allCases: [Self] {
                    [.home, .settings]
                }

                public var title: Swift.String {
                    switch self {
                    case .home:
                        return "Home"
                    case .settings:
                        return "Settings"
                    }
                }

                public var systemImage: Swift.String {
                    switch self {
                    case .home:
                        return "house"
                    case .settings:
                        return "gear"
                    }
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Rejects @TabItem outside an enum case")
    func wrongAttachment() throws {
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
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects a standalone @TabItem enum case")
    func missingRouter() throws {
        assertMacroExpansion(
            """
            enum AppTab {
                @TabItem("Home", systemImage: "house")
                case home
            }
            """,
            expandedSource: """
            enum AppTab {
                case home
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E008] @TabItem requires an enclosing @Router enum; add @Router to the enum or remove @TabItem",
                    line: 2,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects @TabItem when only an outer enum is an @Router")
    func nearestEnclosingEnumRequiresRouter() throws {
        assertMacroExpansion(
            """
            @Router
            enum OuterRoute {
                case home
                enum NestedTab {
                    @TabItem("Settings", systemImage: "gear")
                    case settings
                }
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum OuterRoute {
                case home
                enum NestedTab {
                    case settings
                }
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension OuterRoute: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E008] @TabItem requires an enclosing @Router enum; add @Router to the enum or remove @TabItem",
                    line: 5,
                    column: 9
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Requires every tab-router case to have metadata")
    func partialMarkers() throws {
        assertMacroExpansion(
            """
            @Router
            enum MixedTab {
                @TabItem("Home", systemImage: "house")
                case home
                case settings
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum MixedTab {
                case home
                case settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E009] @Router tab case `settings` is missing @TabItem; annotate every case or remove all @TabItem annotations",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects duplicate metadata on one case")
    func duplicateMarkers() throws {
        assertMacroExpansion(
            """
            @Router
            enum DuplicateTab {
                @TabItem("Home", systemImage: "house")
                @TabItem("Home", systemImage: "house.fill")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum DuplicateTab {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E010] a router tab case must have exactly one @TabItem annotation; remove the duplicate",
                    line: 4,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Requires one enum element per annotated declaration")
    func multipleCasesPerDeclaration() throws {
        assertMacroExpansion(
            """
            @Router
            enum JoinedTab {
                @TabItem("Home", systemImage: "house")
                case home, settings
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum JoinedTab {
                case home, settings
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E011] @TabItem requires one case per declaration; split `case first, second` into separate annotated case declarations",
                    line: 3,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects tab cases with associated values")
    func associatedValue() throws {
        assertMacroExpansion(
            """
            @Router
            enum PayloadTab {
                @TabItem("Detail", systemImage: "doc")
                case detail(id: Int)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum PayloadTab {
                case detail(id: Int)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E012] @Router tab case `detail` cannot have associated values because RouterTab must be CaseIterable",
                    line: 4,
                    column: 10
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "Requires the exact metadata signature",
        arguments: [
            (
                "@TabItem(\"Home\", icon: \"house\")",
                "the second argument label must be exactly `systemImage:`"
            ),
            (
                "@TabItem(title: \"Home\", systemImage: \"house\")",
                "the title must be the first unlabeled argument"
            ),
            (
                "@TabItem(\"Home\")",
                "provide exactly one unlabeled title and one `systemImage:` argument"
            ),
            (
                "@TabItem(\"Home\", systemImage: \"   \")",
                "systemImage must be a nonempty plain string literal"
            ),
        ]
    )
    func invalidSignature(attribute: String, reason: String) throws {
        assertMacroExpansion(
            """
            @Router
            enum WrongLabelTab {
                \(attribute)
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum WrongLabelTab {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E013] @TabItem requires @TabItem(\"Title\", systemImage: \"symbol\"): \(reason)",
                    line: 3,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects empty metadata literals")
    func emptyLiteral() throws {
        assertMacroExpansion(
            """
            @Router
            enum EmptyTitleTab {
                @TabItem("   ", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum EmptyTitleTab {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E013] @TabItem requires @TabItem(\"Title\", systemImage: \"symbol\"): the title must be a nonempty plain string literal",
                    line: 3,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects interpolated metadata")
    func interpolatedLiteral() throws {
        assertMacroExpansion(
            """
            @Router
            enum DynamicTab {
                @TabItem("Home \\(suffix)", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum DynamicTab {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E013] @TabItem requires @TabItem(\"Title\", systemImage: \"symbol\"): the title must be a nonempty plain string literal",
                    line: 3,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects availability-scoped tabs")
    func availableCase() throws {
        assertMacroExpansion(
            """
            @Router
            enum AvailableTab {
                @available(iOS 18, *)
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AvailableTab {
                @available(iOS 18, *)
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E014] @Router tab case `home` cannot be conditionally available because allCases must be stable",
                    line: 3,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects build-configuration-dependent tab sets")
    func conditionalCase() throws {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalTab {
            #if DEBUG
                @TabItem("Debug", systemImage: "wrench")
                case debug
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalTab {
            #if DEBUG
                case debug
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E015] @Router tab cases cannot be declared inside #if; declare one stable tab set for every build configuration",
                    line: 4,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects a conditionally compiled @TabItem attribute")
    func conditionalTabItemAttribute() throws {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalAttributeTab {
            #if DEBUG
                @TabItem("Debug", systemImage: "wrench")
            #endif
                case debug
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAttributeTab {
            #if DEBUG
                @TabItem("Debug", systemImage: "wrench")
            #endif
                case debug
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E015] @Router tab cases cannot be declared inside #if; declare one stable tab set for every build configuration",
                    line: 4,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Conditional @TabItem takes precedence over duplicate diagnostics")
    func directAndConditionalTabItemAttribute() throws {
        assertMacroExpansion(
            """
            @Router
            enum DuplicateConditionalAttributeTab {
                @TabItem("Home", systemImage: "house")
            #if DEBUG
                @TabItem("Debug", systemImage: "wrench")
            #endif
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum DuplicateConditionalAttributeTab {
            #if DEBUG
                @TabItem("Debug", systemImage: "wrench")
            #endif
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E015] @Router tab cases cannot be declared inside #if; declare one stable tab set for every build configuration",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Rejects a conditionally compiled availability attribute on a tab")
    func conditionalAvailabilityAttribute() throws {
        assertMacroExpansion(
            """
            @Router
            enum ConditionalAvailabilityTab {
                @TabItem("Home", systemImage: "house")
            #if DEBUG
                @available(macOS 14, *)
            #endif
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAvailabilityTab {
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
                    message: "[InnoRouterMacro.E014] @Router tab case `home` cannot be conditionally available because allCases must be stable",
                    line: 3,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "Rejects every manual metadata witness",
        arguments: [
            ("static var allCases: [Self] { [.home] }", "allCases"),
            ("var title: String { \"Manual\" }", "title"),
            ("var systemImage: String { \"manual\" }", "systemImage"),
        ]
    )
    func conflictingMember(declaration: String, name: String) throws {
        assertMacroExpansion(
            """
            @Router
            enum ManualTitleTab {
                @TabItem("Home", systemImage: "house")
                case home
                \(declaration)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ManualTitleTab {
                case home
                \(declaration)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E016] @Router with @TabItem generates `\(name)`; remove the manual declaration or remove the tab annotations",
                    line: 5,
                    column: 5
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test(
        "Rejects tab cases that collide with generated witness names",
        arguments: ["allCases", "title", "systemImage"]
    )
    func conflictingCaseName(name: String) throws {
        assertMacroExpansion(
            """
            @Router
            enum ConflictingCaseTab {
                @TabItem("Conflict", systemImage: "exclamationmark.triangle")
                case \(name)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConflictingCaseTab {
                case \(name)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E016] @Router with @TabItem generates `\(name)`; remove the manual declaration or remove the tab annotations",
                    line: 4,
                    column: 10
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Warns once when RouterTab and CaseIterable are both redundant")
    func redundantRouterTab() throws {
        assertMacroExpansion(
            """
            @Router
            enum RedundantTab: RouterTab, CaseIterable {
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum RedundantTab: RouterTab, CaseIterable {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension RedundantTab: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal static var allCases: [Self] {
                    [.home]
                }

                internal var title: Swift.String {
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
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W004] RouterTab conformance is supplied by @Router when @TabItem is present; remove the explicit conformance",
                    line: 2,
                    column: 18,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Warns for redundant CaseIterable conformance")
    func redundantCaseIterable() throws {
        assertMacroExpansion(
            """
            @Router
            enum IterableTab: CaseIterable {
                @TabItem("Home", systemImage: "house")
                case home
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum IterableTab: CaseIterable {
                case home
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension IterableTab: InnoRouterSwiftUI.DestinationRoute, InnoRouterSwiftUI.RouterTab {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                internal static var allCases: [Self] {
                    [.home]
                }

                internal var title: Swift.String {
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
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W005] CaseIterable conformance is inherited from the RouterTab supplied by @Router; remove the explicit conformance",
                    line: 2,
                    column: 17,
                    severity: .warning
                )
            ],
            macros: makeTestMacros()
        )
    }
}

#endif
