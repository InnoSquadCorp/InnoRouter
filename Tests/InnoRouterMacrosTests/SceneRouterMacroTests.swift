// MARK: - SceneRouterMacroTests.swift
// InnoRouter Macros Tests - @SceneRouter + @Scene
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

private let sceneRouterTestMacros: [String: Macro.Type] = [
    "SceneRouter": SceneRouterMacro.self,
    "Scene": SceneMacro.self,
]

@Suite("Scene Router Macro Tests")
struct SceneRouterMacroTests {
    @Test("E001 rejects @SceneRouter on a non-enum declaration")
    func sceneRouterRequiresEnum() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            struct NotASceneRouter {
            }
            """,
            expandedSource: """
            struct NotASceneRouter {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E001] @SceneRouter can only be applied to enum declarations",
                    line: 1,
                    column: 1,
                    fixIts: [FixItSpec(message: "Change `struct` to `enum`")]
                ),
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("Supports every scene style and supplies route destination conformance")
    func validStylesExpansion() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum AppScene {
                @Scene(.window)
                case main

                @Scene(.volumetric(width: 1.5, height: 2, depth: 3), id: "model")
                case model

                @Scene(.immersive(style: .mixed), id: "experience")
                case immersive

                var destination: some View {
                    EmptyView()
                }
            }
            """,
            expandedSource: """
            enum AppScene {
                case main
                case model
                case immersive
                @Swift.MainActor @SwiftUI.ViewBuilder

                var destination: some View {
                    EmptyView()
                }
            }

            extension AppScene: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            macros: sceneRouterTestMacros
        )
    }

    @Test("Preserves explicit destination attributes and public access")
    func attributesAndAccessExpansion() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            public enum PublicScene {
                @Scene(.immersive(style: .full))
                case experience

                @Swift.MainActor
                @SwiftUI.ViewBuilder
                private var destination: some SwiftUI.View {
                    EmptyView()
                }
            }
            """,
            expandedSource: """
            public enum PublicScene {
                case experience

                @Swift.MainActor
                @SwiftUI.ViewBuilder
                private var destination: some SwiftUI.View {
                    EmptyView()
                }
            }

            extension PublicScene: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                public static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            macros: sceneRouterTestMacros
        )
    }

    @Test("E030 rejects @Scene outside an enum case")
    func sceneRequiresCase() throws {
        assertMacroExpansion(
            """
            struct Example {
                @Scene(.window)
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
                    message: "[InnoRouterMacro.E030] @Scene can only be attached to an enum case inside an @SceneRouter enum",
                    line: 2,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E031 requires the nearest enum to be a scene router")
    func sceneRequiresSceneRouter() throws {
        assertMacroExpansion(
            """
            enum StandaloneScene {
                @Scene(.window)
                case main
            }
            """,
            expandedSource: """
            enum StandaloneScene {
                case main
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E031] @Scene requires the nearest enclosing enum to use @SceneRouter",
                    line: 2,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E032 rejects combining @SceneRouter and @Router")
    func conflictsWithRouter() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            @Router
            enum ConflictingScene {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            @Router
            enum ConflictingScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E032] @SceneRouter already supplies route destinations; remove @Router and keep only @SceneRouter",
                    line: 1,
                    column: 1
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E033 rejects an empty scene inventory")
    func emptyRouter() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum EmptyScene {
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum EmptyScene {
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E033] @SceneRouter requires at least one scene case",
                    line: 1,
                    column: 1
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E034 rejects generic scene inventories")
    func genericRouter() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum GenericScene<Value> {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum GenericScene<Value> {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E034] @SceneRouter does not support generic enums because scene cases must form one concrete app inventory",
                    line: 1,
                    column: 1
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E035 rejects cases declared inside conditional compilation")
    func conditionalCase() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum ConditionalScene {
            #if DEBUG
                @Scene(.window)
                case main
            #endif
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalScene {
            #if DEBUG
                case main
            #endif
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E035] @SceneRouter cases cannot be declared inside #if; keep the scene inventory stable across builds",
                    line: 4,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E036 rejects conditionally compiled case attributes")
    func conditionalAttributes() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum ConditionalAttributeScene {
                @Scene(.window)
            #if DEBUG
                @available(macOS 14, *)
            #endif
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ConditionalAttributeScene {
            #if DEBUG
                @available(macOS 14, *)
            #endif
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E036] scene case `main` cannot use conditionally compiled attributes",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E037 requires exactly one @Scene annotation per case")
    func missingScene() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum MissingScene {
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum MissingScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E037] scene case `main` requires exactly one @Scene annotation",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E038 rejects duplicate @Scene annotations")
    func duplicateScene() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum DuplicateScene {
                @Scene(.window)
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum DuplicateScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E038] a scene case must have exactly one @Scene annotation; remove the duplicate",
                    line: 4,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E039 requires one case per declaration")
    func multipleCasesPerDeclaration() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum JoinedScene {
                @Scene(.window)
                case main, utility
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum JoinedScene {
                case main, utility
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E039] @Scene requires one case per declaration; split joined enum cases into separate declarations",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E040 rejects associated values")
    func associatedValues() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum AssociatedScene {
                @Scene(.window)
                case main(Int)
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AssociatedScene {
                case main(Int)
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E040] scene case `main` cannot have associated values; move destination state into the scene's view model",
                    line: 4,
                    column: 10
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E041 rejects conditionally available cases")
    func unavailableCase() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum AvailableScene {
                @available(macOS 14, *)
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AvailableScene {
                @available(macOS 14, *)
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E041] scene case `main` cannot be conditionally available",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E042 rejects unsupported scene arguments")
    func invalidArguments() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum InvalidStyleScene {
                @Scene(.unknown)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum InvalidStyleScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E042] @Scene arguments are invalid: use `.window`, `.volumetric(width:height:depth:)`, or `.immersive(style:)`",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E043 rejects non-positive volumetric dimensions")
    func invalidSize() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum InvalidVolumeScene {
                @Scene(.volumetric(width: 1, height: 0, depth: 2))
                case model
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum InvalidVolumeScene {
                case model
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E043] @Scene volumetric size is invalid: every dimension must be finite and greater than zero",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E044 rejects duplicate scene identifiers")
    func duplicateID() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum DuplicateIDScene {
                @Scene(.window, id: "shared")
                case main
                @Scene(.window, id: "shared")
                case utility
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum DuplicateIDScene {
                case main
                case utility
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E044] @Scene id `shared` is duplicated; every scene identifier must be unique",
                    line: 5,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E045 requires a destination property")
    func missingDestination() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum MissingDestinationScene {
                @Scene(.window)
                case main
            }
            """,
            expandedSource: """
            enum MissingDestinationScene {
                case main
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E045] @SceneRouter requires `var destination: some View { ... }` inside the enum",
                    line: 1,
                    column: 1
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E046 rejects an invalid destination property")
    func invalidDestination() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum StaticDestinationScene {
                @Scene(.window)
                case main
                static var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum StaticDestinationScene {
                case main
                static var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E046] @SceneRouter cannot use this `destination` property: it must be an instance property, not a static property. Declare an instance computed `var destination: some View { ... }`.",
                    line: 5,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E047 rejects the generated destination witness conflict")
    func conflictingDestination() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum ManualDestinationScene {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
                static func destination(for route: Self) -> some View { route.destination }
            }
            """,
            expandedSource: """
            enum ManualDestinationScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
                static func destination(for route: Self) -> some View { route.destination }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E047] @SceneRouter generates `static destination(for:)`; remove the manual function or remove @SceneRouter and conform to DestinationRoute manually",
                    line: 6,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("W008 warns for redundant DestinationRoute conformance")
    func redundantDestinationRoute() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum AppScene: DestinationRoute {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppScene: DestinationRoute {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AppScene {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W008] DestinationRoute conformance is supplied by @SceneRouter; remove the explicit conformance",
                    line: 2,
                    column: 14,
                    severity: .warning
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("W009 warns for redundant Route conformance")
    func redundantRoute() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum AppScene: Route {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppScene: Route {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension AppScene: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W009] Route conformance is inherited from the DestinationRoute supplied by @SceneRouter; remove the explicit conformance",
                    line: 2,
                    column: 14,
                    severity: .warning
                )
            ],
            macros: sceneRouterTestMacros
        )
    }
}

#endif
