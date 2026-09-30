// MARK: - RouterNineteenthReviewMemberConflictTests.swift
// InnoRouterMacrosBehaviorTests - generated member collision classification

#if canImport(InnoRouterMacrosPlugin)

import Foundation
import SwiftUI
import Testing

import InnoRouterMacros

/// The generated `routerTabs` is static, so an instance property of the same
/// name is a legal Swift declaration and must be accepted.
@Router
enum NineteenthTabInstanceRouter {
    @TabItem("Home", systemImage: "house")
    case home

    var routerTabs: String { "instance" }

    var destination: some View { Text("Destination") }
}

/// A conflicting declaration that is compiled out must not be rejected: the
/// generated member is not built for this configuration either.
@Router
enum NineteenthTabConditionalRouter {
    @TabItem("Home", systemImage: "house")
    case home

#if INNOROUTER_NINETEENTH_TAB_CONFLICT
    static var routerTabs: [String] { [] }
#endif

    var destination: some View { Text("Destination") }
}

/// The same rule for scenes.
@Router
enum NineteenthSceneInstanceRouter {
    @Scene(.window, id: "nineteenth-editor")
    case editor

    var routerScenes: String { "instance" }

    var destination: some View { Text("Destination") }
}

@Router
enum NineteenthSceneConditionalRouter {
    @Scene(.window, id: "nineteenth-conditional-editor")
    case editor

#if INNOROUTER_NINETEENTH_SCENE_CONFLICT
    static var routerScenes: [String] { [] }
#endif

    var destination: some View { Text("Destination") }
}

@Suite("Nineteenth review generated member conflicts")
struct RouterNineteenthReviewMemberConflictTests {
    /// AC-020 — the generated static catalog and a manual instance property
    /// of the same name are both usable.
    @Test("A tab router keeps a same-named instance property")
    func tabRouterKeepsInstanceProperty() {
        #expect(NineteenthTabInstanceRouter.routerTabs.count == 1)
        #expect(NineteenthTabInstanceRouter.home.routerTabs == "instance")
    }

    /// AC-021 — an inactive conflicting declaration is not a conflict.
    @Test("A tab router accepts a compiled-out conflicting declaration")
    func tabRouterAcceptsInactiveConflict() {
        #expect(NineteenthTabConditionalRouter.routerTabs.count == 1)
    }

    /// AC-020 — the same contract for scenes.
    @Test("A scene router keeps a same-named instance property")
    func sceneRouterKeepsInstanceProperty() {
        #expect(NineteenthSceneInstanceRouter.routerScenes.count == 1)
        #expect(NineteenthSceneInstanceRouter.editor.routerScenes == "instance")
    }

    /// AC-021 — an inactive conflicting scene declaration is not a conflict.
    @Test("A scene router accepts a compiled-out conflicting declaration")
    func sceneRouterAcceptsInactiveConflict() {
        #expect(NineteenthSceneConditionalRouter.routerScenes.count == 1)
    }
}

#endif
