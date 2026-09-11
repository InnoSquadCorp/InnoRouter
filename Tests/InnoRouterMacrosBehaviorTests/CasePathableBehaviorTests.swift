// MARK: - CasePathableBehaviorTests.swift
// InnoRouterMacrosBehaviorTests - @CasePathable runtime semantics
// Copyright © 2025 Inno Squad. All rights reserved.

// MARK: - Platform: InnoRouterMacrosPlugin is a host-only CompilerPlugin.
// On non-macOS simulator builds Xcode flattens the plugin as a regular
// dependency and the linker pulls the macOS-built .o into the test
// binary. Gate the whole file so non-macOS platforms compile an empty
// module; the expansion semantics verified here are exercised on the
// macOS CI leg instead.
#if canImport(InnoRouterMacrosPlugin)

import Testing
import InnoRouterMacros

// MARK: - Fixtures

@CasePathable
enum UIEvent {
    case tapped
    case opened(id: String)
    case swiped(dx: Int, dy: Int)
}

@CasePathable
enum EscapedKeywordEvent {
    case `default`
    case `switch`(id: String)
}

@CasePathable
enum ConditionalEvent {
#if os(macOS)
    case desktop(id: String)
#else
    case portable(id: String)
#endif
}

@Routable
enum ConditionalRouteEvent {
#if os(macOS)
    case desktop
#else
    case portable
#endif
}

// MARK: - @Suite

@Suite("CasePathableBehaviorTests")
struct CasePathableBehaviorTests {

    // MARK: - embed/extract roundtrips

    @Test("parameterless case roundtrips through CasePath")
    func embedExtract_roundtrip_parameterless() {
        let path = UIEvent.Cases.tapped
        let embedded = path.embed(())
        let extracted: Void? = path.extract(embedded)
        #expect(extracted != nil)

        let mismatched: Void? = path.extract(.opened(id: "x"))
        #expect(mismatched == nil)
    }

    @Test("single labeled case roundtrips preserving identifier")
    func embedExtract_roundtrip_singleLabeled() {
        let path = UIEvent.Cases.opened
        let embedded = path.embed("home")
        let extracted = path.extract(embedded)
        #expect(extracted == "home")
    }

    @Test("two labeled case preserves tuple order")
    func embedExtract_roundtrip_twoLabeled() {
        let path = UIEvent.Cases.swiped
        let embedded = path.embed((3, -4))
        let extracted = path.extract(embedded)
        #expect(extracted?.0 == 3)
        #expect(extracted?.1 == -4)
    }

    @Test("escaped keyword cases roundtrip through CasePath")
    func embedExtract_roundtrip_escapedKeywordCases() {
        let defaultEmbedded = EscapedKeywordEvent.Cases.`default`.embed(())
        let defaultExtracted: Void? = EscapedKeywordEvent.Cases.`default`.extract(defaultEmbedded)
        #expect(defaultExtracted != nil)

        let switchPath = EscapedKeywordEvent.Cases.`switch`
        let switchEmbedded = switchPath.embed("settings")
        #expect(switchPath.extract(switchEmbedded) == "settings")
        #expect(switchPath.extract(.`default`) == nil)
    }

    @Test("conditional cases expose only the active branch's CasePath")
    func conditionalCaseRoundtrip() {
#if os(macOS)
        let path = ConditionalEvent.Cases.desktop
        #expect(path.extract(path.embed("mac")) == "mac")
#else
        let path = ConditionalEvent.Cases.portable
        #expect(path.extract(path.embed("portable")) == "portable")
#endif
    }

    @Test("Routable conditional cases preserve Route conformance and CasePath")
    func conditionalRoutableCaseRoundtrip() {
#if os(macOS)
        let route: any Route = ConditionalRouteEvent.desktop
        #expect(route is ConditionalRouteEvent)
        #expect(ConditionalRouteEvent.desktop.is(ConditionalRouteEvent.Cases.desktop))
#else
        let route: any Route = ConditionalRouteEvent.portable
        #expect(route is ConditionalRouteEvent)
        #expect(ConditionalRouteEvent.portable.is(ConditionalRouteEvent.Cases.portable))
#endif
    }

    // MARK: - is(_:)

    @Test("is(_:) distinguishes between CasePathable cases")
    func isDistinguishesCases() {
        let event: UIEvent = .opened(id: "detail")
        #expect(event.is(UIEvent.Cases.opened))
        #expect(!event.is(UIEvent.Cases.swiped))
        #expect(!event.is(UIEvent.Cases.tapped))
    }

    // MARK: - subscript[case:]

    @Test("subscript[case:] returns value only for matching case")
    func subscriptCaseMatchesOnlyCorrectCase() {
        let tap: UIEvent = .tapped
        #expect(tap[case: UIEvent.Cases.opened] == nil)

        let open: UIEvent = .opened(id: "profile")
        #expect(open[case: UIEvent.Cases.opened] == "profile")

        // NOTE: Tuple-valued subscript form (`event[case: UIEvent.Cases.swiped]`)
        // currently triggers a Swift 6.3 SIL-lowering crash for generic subscripts
        // returning `(T, U)?`. Tuple extraction is still covered directly above via
        // `path.extract(_:)`, which uses the same generator output.
    }

    // MARK: - Documentation note

    // NOTE: `@CasePathable` intentionally does NOT synthesize `Route` conformance.
    // Verifying the absence of a conformance at runtime is awkward (and would rely
    // on reflection). This behavior is guarded by the macro definition itself
    // (`Macros.swift` declares no `@attached(extension, conformances:)` for
    // `@CasePathable`) and by plugin-level expansion tests in
    // `Tests/InnoRouterMacrosTests`. Leaving a comment here so the contrast with
    // `@Routable` is discoverable to future contributors.
}

#endif
