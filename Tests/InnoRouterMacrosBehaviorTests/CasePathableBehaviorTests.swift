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

@CasePathable
enum CollidingBindingEvent {
    case mixed(Int, v0: String)
}

// A keyword is legal as an argument label but not as a binding name. These
// cases previously expanded to `let in`, which crashed swift-frontend.
@CasePathable
enum KeywordLabelEvent: Equatable {
    case single(in: Int)
    case pair(where: String, repeat: Bool)
    case mixedKeywords(as: Int, in: Int)
    case keywordAndPlain(for: Int, id: String)
    case escapedLabel(`default`: Int)
}

struct SelfNamedPayload {
    let value: Int
}

@CasePathable
indirect enum RecursivePayloadEvent {
    case end
    case next(Self)
    case optional(Self?)
    case many([Self])
    case tuple(Self, Self?)
    case generic(Result<Self, Never>)
    case named(SelfNamedPayload)
}

enum CasePathNamespace {
    @CasePathable
    indirect enum NestedRecursivePayload {
        case end
        case next(Self)
    }
}

@CasePathable
enum ConditionalAvailabilityEvent {
    case regular
#if os(macOS)
    @available(macOS 26.0, *)
#endif
    case future

#if os(macOS)
#if arch(arm64)
    @available(macOS 26.0, *)
#endif
#endif
    case nestedFuture

#if os(macOS)
    @available(macOS 26.0, *)
#else
    @available(iOS 18.0, *)
#endif
    case branchFuture
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

    // MARK: - keyword argument labels

    @Test("keyword argument label roundtrips through CasePath")
    func embedExtract_roundtrip_keywordLabel() {
        let path = KeywordLabelEvent.Cases.single
        let embedded = path.embed(7)
        #expect(path.extract(embedded) == 7)

        // The label must survive as written, so the embedded value has to
        // match a hand-written `.single(in:)`.
        #expect(embedded == KeywordLabelEvent.single(in: 7))
        #expect(path.extract(.escapedLabel(default: 1)) == nil)
    }

    @Test("two keyword argument labels roundtrip through CasePath")
    func embedExtract_roundtrip_keywordLabelPair() {
        let path = KeywordLabelEvent.Cases.pair
        let embedded = path.embed(("x", true))
        let extracted = path.extract(embedded)
        #expect(extracted?.0 == "x")
        #expect(extracted?.1 == true)
        #expect(embedded == KeywordLabelEvent.pair(where: "x", repeat: true))
    }

    @Test("repeated keyword labels bind to distinct values")
    func embedExtract_roundtrip_repeatedKeywordLabels() {
        // `as` and `in` are both keywords; each needs its own escaped
        // binding or the extract would reuse one name twice.
        let path = KeywordLabelEvent.Cases.mixedKeywords
        let extracted = path.extract(path.embed((1, 2)))
        #expect(extracted?.0 == 1)
        #expect(extracted?.1 == 2)
    }

    @Test("keyword and ordinary labels mix in one case")
    func embedExtract_roundtrip_keywordAndPlainLabels() {
        let path = KeywordLabelEvent.Cases.keywordAndPlain
        let extracted = path.extract(path.embed((3, "id")))
        #expect(extracted?.0 == 3)
        #expect(extracted?.1 == "id")
    }

    @Test("author-escaped label keeps its single escaping")
    func embedExtract_roundtrip_escapedLabel() {
        let path = KeywordLabelEvent.Cases.escapedLabel
        let embedded = path.embed(9)
        #expect(path.extract(embedded) == 9)
        #expect(embedded == KeywordLabelEvent.escapedLabel(default: 9))
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

    @Test("generated extraction bindings remain unique")
    func collidingBindingsRoundtrip() {
        let path = CollidingBindingEvent.Cases.mixed
        let embedded = path.embed((7, "seven"))
        let extracted = path.extract(embedded)
        #expect(extracted?.0 == 7)
        #expect(extracted?.1 == "seven")
    }

    @Test("Self payloads resolve to the enclosing enum")
    func recursiveSelfPayloadRoundtrip() {
        let path = RecursivePayloadEvent.Cases.next
        let embedded = path.embed(.end)
        guard let extracted = path.extract(embedded) else {
            Issue.record("Expected recursive payload extraction")
            return
        }
        if case .end = extracted {
        } else {
            Issue.record("Expected the enclosing enum payload")
        }

        let optional = RecursivePayloadEvent.Cases.optional
        #expect(optional.extract(optional.embed(nil)) != nil)
        let many = RecursivePayloadEvent.Cases.many
        #expect(many.extract(many.embed([.end]))?.count == 1)
        let tuple = RecursivePayloadEvent.Cases.tuple
        #expect(tuple.extract(tuple.embed((.end, nil)))?.1 == nil)
        let generic = RecursivePayloadEvent.Cases.generic
        guard case .success(.end)? = generic.extract(generic.embed(.success(.end))) else {
            Issue.record("Expected Self nested in a generic payload")
            return
        }
        let named = RecursivePayloadEvent.Cases.named
        #expect(named.extract(named.embed(.init(value: 42)))?.value == 42)
        let nested = CasePathNamespace.NestedRecursivePayload.Cases.next
        guard case .end? = nested.extract(nested.embed(.end)) else {
            Issue.record("Expected nested enum Self to resolve to its declaration")
            return
        }
    }

#if os(macOS)
    @available(macOS 26.0, *)
#endif
    @Test("conditional availability reaches generated CasePath members")
    func conditionalAvailabilityRoundtrip() {
        let path = ConditionalAvailabilityEvent.Cases.future
        let extracted: Void? = path.extract(path.embed(()))
        #expect(extracted != nil)
        _ = ConditionalAvailabilityEvent.Cases.nestedFuture.embed(())
        _ = ConditionalAvailabilityEvent.Cases.branchFuture.embed(())
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
