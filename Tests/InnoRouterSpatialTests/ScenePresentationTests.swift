// MARK: - ScenePresentationTests.swift
// Value-level tests for ScenePresentation + OrnamentAnchor.
// These types live in InnoRouterSpatial and are platform-neutral, so the
// tests run on every platform InnoRouter ships for (iOS, iPadOS, macOS,
// tvOS, watchOS, visionOS).
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Testing

import InnoRouterCore
import InnoRouterSpatial

@Suite("ScenePresentation Tests", .tags(.unit))
struct ScenePresentationTests {
    enum SpatialRoute: String, Route, Codable {
        case dashboard
        case detail
        case theatre
    }

    @Test("ScenePresentation.window round-trips through JSON")
    func windowRoundTrip() throws {
        let original: ScenePresentation<SpatialRoute> = .window(.dashboard)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScenePresentation<SpatialRoute>.self, from: data)
        #expect(decoded == original)
    }

    @Test("ScenePresentation.volumetric round-trips through JSON with size")
    func volumetricRoundTrip() throws {
        let original: ScenePresentation<SpatialRoute> = .volumetric(
            .detail,
            size: VolumetricSize(x: 0.8, y: 0.6, z: 0.4)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScenePresentation<SpatialRoute>.self, from: data)
        #expect(decoded == original)
    }

    @Test("ScenePresentation.volumetric round-trips when size is nil")
    func volumetricRoundTripNilSize() throws {
        let original: ScenePresentation<SpatialRoute> = .volumetric(.detail, size: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScenePresentation<SpatialRoute>.self, from: data)
        #expect(decoded == original)
    }

    @Test(
        "ScenePresentation.immersive round-trips for every immersion style",
        arguments: [
            ImmersiveStyle.mixed,
            ImmersiveStyle.progressive,
            ImmersiveStyle.full
        ]
    )
    func immersiveRoundTrip(style: ImmersiveStyle) throws {
        let original: ScenePresentation<SpatialRoute> = .immersive(.theatre, style: style)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScenePresentation<SpatialRoute>.self, from: data)
        #expect(decoded == original)
    }

    @Test("Different ScenePresentation cases are not equal")
    func caseInequality() {
        let window: ScenePresentation<SpatialRoute> = .window(.dashboard)
        let volumetric: ScenePresentation<SpatialRoute> = .volumetric(.dashboard)
        let immersive: ScenePresentation<SpatialRoute> = .immersive(.dashboard, style: .mixed)

        #expect(window != volumetric)
        #expect(window != immersive)
        #expect(volumetric != immersive)
    }

    @Test("Same case with different immersion styles are not equal")
    func immersionStyleInequality() {
        let mixed: ScenePresentation<SpatialRoute> = .immersive(.theatre, style: .mixed)
        let full: ScenePresentation<SpatialRoute> = .immersive(.theatre, style: .full)
        #expect(mixed != full)
    }

    @Test("Same route with different instance ids are not equal")
    func instanceIDInequality() {
        let first: ScenePresentation<SpatialRoute> = .window(
            .dashboard,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second: ScenePresentation<SpatialRoute> = .window(
            .dashboard,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        #expect(first != second)
    }

    @Test("Volumetric size inequality surfaces through Equatable")
    func volumetricSizeInequality() {
        let a: ScenePresentation<SpatialRoute> = .volumetric(.detail, size: VolumetricSize(x: 1, y: 1, z: 1))
        let b: ScenePresentation<SpatialRoute> = .volumetric(.detail, size: VolumetricSize(x: 2, y: 2, z: 2))
        #expect(a != b)
    }
}

@Suite("OrnamentAnchor Tests", .tags(.unit))
struct OrnamentAnchorTests {
    @Test("Default alignment is center")
    func defaultAlignment() {
        let anchor = OrnamentAnchor(anchor: .bottom)
        #expect(anchor.alignment == .center)
    }

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let original = OrnamentAnchor(anchor: .topTrailing, alignment: .bottom)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OrnamentAnchor.self, from: data)
        #expect(decoded == original)
    }

    @Test("Distinct anchors are not equal")
    func anchorInequality() {
        #expect(
            OrnamentAnchor(anchor: .bottom) != OrnamentAnchor(anchor: .top)
        )
    }
}
