// MARK: - InnoRouter.swift
// Umbrella module that re-exports the public InnoRouter surface.
//
// `import InnoRouter` is the canonical entry point for application
// code: it pulls in the typed-state core, the SwiftUI authority
// layer, and the deep-link planner together so callers do not have
// to enumerate every sub-module by hand.
//
// `InnoRouterEffects` is deliberately *not* re-exported. Its
// app-boundary execution helpers are opt-in, so view-layer code that
// only needs stores and hosts does not inherit that additional API.
//
// `InnoRouterMacros` is also deliberately excluded from the umbrella.
// Importing the macros target triggers a SwiftSyntax plugin
// resolution step at compile time; pulling that in for every consumer
// of the umbrella would impose macro-plugin build cost on apps that
// hand-conform their routes. Apps that want `@Routable` /
// `@CasePathable` should `import InnoRouterMacros` explicitly.

@_exported import InnoRouterCore
@_exported import InnoRouterSwiftUI
@_exported import InnoRouterDeepLink
