// MARK: - RouterNineteenthReviewNestedGenericTests.swift
// InnoRouterMacrosBehaviorTests - nested generic helper contexts

#if canImport(InnoRouterMacrosPlugin)

import Foundation
import SwiftUI
import Testing

import InnoRouterMacros

enum NineteenthNestedNamespace {
    /// A generic router declared inside another type.
    @Router
    indirect enum NestedGenericRouter<Value: Hashable & Sendable> {
        case leaf(Value)

        @PresentationResult(Self.self)
        case recursive

        @PresentationResult(Bool.self)
        case login

        @Scene(.window, id: "nested-editor")
        case editor

        var destination: some View { Text("Destination") }
    }
}

struct NineteenthGenericNamespace<Value: Hashable & Sendable> {
    /// A non-generic router declared inside a generic type.
    @Router
    enum InnerRouter {
        @PresentationResult(Bool.self)
        case login

        @Scene(.window, id: "inner-editor")
        case editor

        var destination: some View { Text("Destination") }
    }
}

/// A nested generic router with a `where` clause, consumed as a typed value.
enum NineteenthConstrainedNamespace {
    @Router
    enum ConstrainedRouter<Value> where Value: Hashable & Sendable {
        case leaf(Value)

        @PresentationResult(Bool.self)
        case login

        var destination: some View { Text("Destination") }
    }
}

@Suite("Nineteenth review nested generic helpers")
struct RouterNineteenthReviewNestedGenericTests {
    typealias NestedInt = NineteenthNestedNamespace.NestedGenericRouter<Int>

    /// AC-017 — the nested generic router's helpers are consumed as typed
    /// values, not merely generated.
    @Test("A generic router nested in another type keeps its helper contexts")
    func nestedGenericRouterKeepsHelperContexts() {
        let login: RouterPresentationRequest<NestedInt, Bool> = NestedInt.Presentation.login
        #expect(login.route == .login)

        // The result type is the enclosing route itself, so `Self` has to
        // resolve to the specialized parent.
        let recursive: RouterPresentationRequest<NestedInt, NestedInt> =
            NestedInt.Presentation.recursive
        #expect(recursive.route == .recursive)

        let window: RouterWindowRequest<NestedInt> = NestedInt.Scene.editor
        #expect(window.sceneID == "nested-editor")
        #expect(NestedInt.routerScenes.count == 1)
    }

    /// AC-018 — a `where` clause is part of the same parent context.
    @Test("A where-constrained nested generic router keeps its helper contexts")
    func constrainedNestedGenericRouterKeepsHelperContexts() {
        let login: RouterPresentationRequest<
            NineteenthConstrainedNamespace.ConstrainedRouter<String>,
            Bool
        > = NineteenthConstrainedNamespace.ConstrainedRouter<String>.Presentation.login
        #expect(login.route == .login)
    }

    /// AC-017 control — a non-generic router nested in a generic type.
    @Test("A router nested in a generic type keeps its helper contexts")
    func routerNestedInGenericTypeKeepsHelperContexts() {
        let login: RouterPresentationRequest<NineteenthGenericNamespace<Int>.InnerRouter, Bool> =
            NineteenthGenericNamespace<Int>.InnerRouter.Presentation.login
        #expect(login.route == .login)

        let window: RouterWindowRequest<NineteenthGenericNamespace<Int>.InnerRouter> =
            NineteenthGenericNamespace<Int>.InnerRouter.Scene.editor
        #expect(window.sceneID == "inner-editor")
    }
}

#endif
