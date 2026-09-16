#if canImport(InnoRouterMacrosPlugin)
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Nineteenth review generated member conflict diagnostics")
struct RouterNineteenthReviewConflictTests {
    /// AC-022 — a real static collision is still rejected.
    @Test("E016 rejects a manual static routerTabs")
    func staticRouterTabsConflict() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @TabItem("Home", systemImage: "house")
                case home
                static var routerTabs: [String] { [] }
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case home
                static var routerTabs: [String] { [] }
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E016] @Router with @TabItem generates `routerTabs`; remove the manual declaration or remove the tab annotations",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    /// AC-022 — the same for scenes.
    @Test("E048 rejects a manual static routerScenes")
    func staticRouterScenesConflict() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @Scene(.window, id: "editor")
                case editor
                static var routerScenes: [String] { [] }
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case editor
                static var routerScenes: [String] { [] }
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E048] @Router with @Scene generates `routerScenes`; remove the manual declaration or all scene markers",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }

    /// AC-022 — a nested type that shadows the generated namespace is still a
    /// conflict.
    @Test("E048 rejects a manual nested Scene type")
    func nestedSceneTypeConflict() {
        assertMacroExpansion(
            """
            @Router
            enum AppRoute {
                @Scene(.window, id: "editor")
                case editor
                enum Scene {}
                var destination: some View { EmptyView() }
            }
            """,
            expandedSource: """
            enum AppRoute {
                case editor
                enum Scene {}
                @Swift.MainActor @SwiftUI.ViewBuilder
                var destination: some View { EmptyView() }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E048] @Router with @Scene generates `Scene`; remove the manual declaration or all scene markers",
                    line: 5,
                    column: 5
                ),
            ],
            macros: makeTestMacros()
        )
    }
}
#endif
