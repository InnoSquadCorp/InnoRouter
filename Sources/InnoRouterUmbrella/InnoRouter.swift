// MARK: - InnoRouter.swift
// Umbrella module that re-exports the public InnoRouter surface.
//
// `import InnoRouter` is the canonical entry point for application
// code: it pulls in the typed-state core, the SwiftUI authority
// layer, the deep-link planner, and the macro declarations together
// so callers do not have to enumerate every sub-module by hand.
//
// InnoRouter 6 intentionally publishes no granular runtime products. A
// consumer adds one product, writes `import InnoRouter`, and receives the
// generated route declaration, canonical state/store, native hosts, and
// complete-plan deep-link pipeline together. Testing and inspector support
// remain separate opt-in developer products.

@_exported import InnoRouterCore
@_exported import InnoRouterSwiftUI
@_exported import InnoRouterDeepLink
@_exported import InnoRouterMacros
@_exported import InnoRouterSystem
