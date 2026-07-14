// MARK: - SceneLocalizedDescriptionTests.swift
// InnoRouterSpatialTests — user-facing spatial rejection descriptions
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing

import InnoRouterSpatial

@Suite("Spatial localized description surfaces", .tags(.unit))
struct SceneLocalizedDescriptionTests {
    @Test("scene rejection exposes localizedDescription")
    func sceneRejectionDescription() {
        #expect(SceneRejectionReason.sceneNotDeclared.localizedDescription.contains("declared"))
    }
}
