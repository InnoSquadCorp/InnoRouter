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

                #if os(visionOS)
                @Swift.MainActor
                internal static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<AppScene>()

                    @SwiftUI.State
                    private var _innoRouterImmersionStyle2: any SwiftUI.ImmersionStyle =
                        SwiftUI.MixedImmersionStyle()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<AppScene>(
                        .window(.main, id: "main"),
                        .volumetric(
                            .model,
                            id: "model",
                            size: InnoRouterSpatial.VolumetricSize(
                                x: 1.5,
                                y: 2.0,
                                z: 3.0
                            )
                        ),
                        .immersive(.immersive, id: "experience", style: .mixed)
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.WindowGroup(
                            id: "main",
                            for: Foundation.UUID.self
                        ) { $sceneID in
                            AppScene.destination(for: .main)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .main,
                                    instanceID: sceneID
                                )
                        } defaultValue: {
                            Foundation.UUID()
                        }

                        SwiftUI.WindowGroup(
                            id: "model",
                            for: Foundation.UUID.self
                        ) { $sceneID in
                            AppScene.destination(for: .model)
                                .innoRouterSceneAnchor(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .model,
                                    instanceID: sceneID
                                )
                        } defaultValue: {
                            Foundation.UUID()
                        }
                        .windowStyle(SwiftUI.VolumetricWindowStyle())
                        .defaultSize(
                            width: 1.5,
                            height: 2.0,
                            depth: 3.0,
                            in: Foundation.UnitLength.meters
                        )

                        SwiftUI.ImmersiveSpace(id: "experience") {
                            AppScene.destination(for: .immersive)
                                .innoRouterSceneAnchor(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .immersive
                                )
                        }
                        .immersionStyle(
                            selection: $_innoRouterImmersionStyle2,
                            in: SwiftUI.MixedImmersionStyle()
                        )
                    }
                }
                #endif
            }
            """,
            macros: sceneRouterTestMacros
        )
    }

    @Test("Preserves explicit destination attributes and public access")
    func attributesAndAccessExpansion() throws {
        assertMacroExpansion(
            """
            @SceneRouter(immersiveLaunch: true)
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

                #if os(visionOS)
                @Swift.MainActor
                public static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<PublicScene>()

                    @SwiftUI.State
                    private var _innoRouterImmersionStyle0: any SwiftUI.ImmersionStyle =
                        SwiftUI.FullImmersionStyle()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<PublicScene>(
                        .immersive(.experience, id: "experience", style: .full)
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.ImmersiveSpace(id: "experience") {
                            PublicScene.destination(for: .experience)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .experience
                                )
                        }
                        .immersionStyle(
                            selection: $_innoRouterImmersionStyle0,
                            in: SwiftUI.FullImmersionStyle()
                        )
                    }
                }
                #endif
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
}

@Suite("Scene Router Macro Validation and Composition Tests")
struct SceneRouterMacroValidationAndCompositionTests {
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

    @Test("E048 rejects a generated scene member conflict")
    func conflictingGeneratedSceneMember() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum ManualSceneTree {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
                static var scenes: some Scene { EmptyScene() }
            }
            """,
            expandedSource: """
            enum ManualSceneTree {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
                static var scenes: some Scene { EmptyScene() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E048] @SceneRouter generates `static var scenes`; remove the manual declaration or remove @SceneRouter and compose spatial scenes manually",
                    line: 6,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("Allows a non-visionOS scene-tree fallback")
    func conditionalNonVisionSceneMember() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum CrossPlatformSceneTree {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            #if !os(visionOS)
                static var scenes: some Scene { EmptyScene() }
            #endif
            }
            """,
            expandedSource: """
            enum CrossPlatformSceneTree {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            #if !os(visionOS)
                static var scenes: some Scene { EmptyScene() }
            #endif
            }

            extension CrossPlatformSceneTree: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                #if os(visionOS)
                @Swift.MainActor
                internal static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<CrossPlatformSceneTree>()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<CrossPlatformSceneTree>(
                        .window(.main, id: "main")
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.WindowGroup(
                            id: "main",
                            for: Foundation.UUID.self
                        ) { $sceneID in
                            CrossPlatformSceneTree.destination(for: .main)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .main,
                                    instanceID: sceneID
                                )
                        } defaultValue: {
                            Foundation.UUID()
                        }
                    }
                }
                #endif
            }
            """,
            macros: sceneRouterTestMacros
        )
    }

    @Test("E049 rejects unsupported @SceneRouter arguments")
    func invalidSceneRouterArguments() throws {
        assertMacroExpansion(
            """
            @SceneRouter(primary: true)
            enum InvalidOptionsScene {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum InvalidOptionsScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E049] @SceneRouter arguments are invalid: use only the optional `immersiveLaunch: true` acknowledgement",
                    line: 1,
                    column: 1
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("E042 rejects interpolated scene identifiers")
    func interpolatedID() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum InterpolatedIDScene {
                @Scene(.window, id: "prefix-\\(suffix)")
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum InterpolatedIDScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E042] @Scene arguments are invalid: `id` must be one nonempty noninterpolated string literal",
                    line: 3,
                    column: 5
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("Escaped-equivalent identifiers are canonicalized before duplicate validation")
    func escapedEquivalentDuplicateID() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum EscapedDuplicateIDScene {
                @Scene(.window, id: "sha\\u{72}ed")
                case main
                @Scene(.window, id: "shared")
                case utility
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum EscapedDuplicateIDScene {
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

    @Test("Generated scene identifiers preserve Swift literal semantics")
    func generatedStringLiteralEscaping() {
        #expect(
            sceneRouterStringLiteral("tab\tline\nquote\"slash\\control\u{7f}\u{85}\u{2028}\u{2029}") ==
                "\"tab\\tline\\nquote\\\"slash\\\\control\\u{7f}\\u{85}\\u{2028}\\u{2029}\""
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

                #if os(visionOS)
                @Swift.MainActor
                internal static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<AppScene>()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<AppScene>(
                        .window(.main, id: "main")
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.WindowGroup(
                            id: "main",
                            for: Foundation.UUID.self
                        ) { $sceneID in
                            AppScene.destination(for: .main)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .main,
                                    instanceID: sceneID
                                )
                        } defaultValue: {
                            Foundation.UUID()
                        }
                    }
                }
                #endif
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

                #if os(visionOS)
                @Swift.MainActor
                internal static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<AppScene>()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<AppScene>(
                        .window(.main, id: "main")
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.WindowGroup(
                            id: "main",
                            for: Foundation.UUID.self
                        ) { $sceneID in
                            AppScene.destination(for: .main)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .main,
                                    instanceID: sceneID
                                )
                        } defaultValue: {
                            Foundation.UUID()
                        }
                    }
                }
                #endif
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

    @Test("W010 warns when an immersive scene becomes the primary host without launch acknowledgement")
    func immersivePrimaryHostRequiresAcknowledgement() throws {
        assertMacroExpansion(
            """
            @SceneRouter
            enum ImmersivePrimaryScene {
                @Scene(.immersive(style: .mixed))
                case theatre
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum ImmersivePrimaryScene {
                case theatre
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension ImmersivePrimaryScene: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                #if os(visionOS)
                @Swift.MainActor
                internal static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<ImmersivePrimaryScene>()

                    @SwiftUI.State
                    private var _innoRouterImmersionStyle0: any SwiftUI.ImmersionStyle =
                        SwiftUI.MixedImmersionStyle()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<ImmersivePrimaryScene>(
                        .immersive(.theatre, id: "theatre", style: .mixed)
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.ImmersiveSpace(id: "theatre") {
                            ImmersivePrimaryScene.destination(for: .theatre)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .theatre
                                )
                        }
                        .immersionStyle(
                            selection: $_innoRouterImmersionStyle0,
                            in: SwiftUI.MixedImmersionStyle()
                        )
                    }
                }
                #endif
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W010] the first @SceneRouter case becomes the primary host, but an immersive host cannot dispatch until the system opens it; move a window or volume first, or set `UIApplicationPreferredDefaultSceneSessionRole` to `UISceneSessionRoleImmersiveSpaceApplication` and acknowledge it with `@SceneRouter(immersiveLaunch: true)`",
                    line: 1,
                    column: 1,
                    severity: .warning
                )
            ],
            macros: sceneRouterTestMacros
        )
    }

    @Test("W011 warns when immersive launch acknowledgement is unnecessary")
    func unusedImmersiveLaunchAcknowledgement() throws {
        assertMacroExpansion(
            """
            @SceneRouter(immersiveLaunch: true)
            enum WindowPrimaryScene {
                @Scene(.window)
                case main
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum WindowPrimaryScene {
                case main
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }

            extension WindowPrimaryScene: InnoRouterSwiftUI.DestinationRoute {
                @Swift.MainActor
                @SwiftUI.ViewBuilder
                internal static func destination(for route: Self) -> some SwiftUI.View {
                    route.destination
                }

                #if os(visionOS)
                @Swift.MainActor
                internal static var scenes: some SwiftUI.Scene {
                    _InnoRouterSceneContainer()
                }

                @Swift.MainActor
                private struct _InnoRouterSceneContainer: SwiftUI.Scene {
                    @SwiftUI.State
                    private var _innoRouterStore = InnoRouterSpatial.SceneStore<WindowPrimaryScene>()

                    private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<WindowPrimaryScene>(
                        .window(.main, id: "main")
                    )

                    @SwiftUI.SceneBuilder
                    var body: some SwiftUI.Scene {
                        SwiftUI.WindowGroup(
                            id: "main",
                            for: Foundation.UUID.self
                        ) { $sceneID in
                            WindowPrimaryScene.destination(for: .main)
                                .innoRouterSceneHost(
                                    _innoRouterStore,
                                    scenes: _innoRouterScenes,
                                    attachedTo: .main,
                                    instanceID: sceneID
                                )
                        } defaultValue: {
                            Foundation.UUID()
                        }
                    }
                }
                #endif
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.W011] `immersiveLaunch: true` is only needed when the first scene is immersive; remove it while a window or volume is the primary host",
                    line: 1,
                    column: 1,
                    severity: .warning
                )
            ],
            macros: sceneRouterTestMacros
        )
    }
}

#endif
