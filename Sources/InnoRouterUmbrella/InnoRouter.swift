// MARK: - InnoRouter.swift
// Umbrella module that re-exports the public InnoRouter surface.
//
// `import InnoRouter` is the canonical entry point for application
// code: it pulls in the typed-state core, the SwiftUI authority
// layer, the deep-link planner, and the macro declarations together
// so callers do not have to enumerate every sub-module by hand.
//
// `InnoRouterEffects` is deliberately *not* re-exported. Its
// app-boundary execution helpers are opt-in, so view-layer code that
// only needs stores and hosts does not inherit that additional API.
//
// `InnoRouterSpatial` is also opt-in. Apps that coordinate visionOS
// windows, volumes, immersive spaces, or ornaments import that product
// explicitly; the umbrella remains free of spatial scene authority.
//
// InnoRouter 5 makes macros part of the canonical entry point so a
// consumer can add one product, write `import InnoRouter`, and use
// `@Router` immediately. Consumers that intentionally avoid compiler
// plugins can depend on the granular `InnoRouterCore`,
// `InnoRouterSwiftUI`, and `InnoRouterDeepLink` products instead.

@_exported import InnoRouterCore
@_exported import InnoRouterSwiftUI
@_exported import InnoRouterDeepLink
@_exported import InnoRouterMacros
