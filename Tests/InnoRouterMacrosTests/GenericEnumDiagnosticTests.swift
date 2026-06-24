// MARK: - GenericEnumDiagnosticTests.swift
// InnoRouterMacrosTests - generic enum rejection coverage for @Routable / @CasePathable
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Generic Enum Diagnostic Tests")
struct GenericEnumDiagnosticTests {
    @Test("@Routable rejects a generic enum with a clear diagnostic")
    func testRoutableRejectsGenericEnum() throws {
        assertMacroExpansion(
            """
            @Routable
            enum Generic<T> {
                case detail(T)
            }
            """,
            expandedSource: """
            enum Generic<T> {
                case detail(T)
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E003] @Routable does not support generic enum declarations. Generic parameters cannot be propagated through the generated `CasePath` members. Consider separating generic cases into a non-generic wrapper enum.",
                    line: 2,
                    column: 13
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("@Routable rejects a constrained generic enum")
    func testRoutableRejectsConstrainedGenericEnum() throws {
        assertMacroExpansion(
            """
            @Routable
            enum Constrained<T: Sendable> {
                case detail(T)
            }
            """,
            expandedSource: """
            enum Constrained<T: Sendable> {
                case detail(T)
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E003] @Routable does not support generic enum declarations. Generic parameters cannot be propagated through the generated `CasePath` members. Consider separating generic cases into a non-generic wrapper enum.",
                    line: 2,
                    column: 17
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("@CasePathable rejects a generic enum with a clear diagnostic")
    func testCasePathableRejectsGenericEnum() throws {
        assertMacroExpansion(
            """
            @CasePathable
            enum GenericPathable<T> {
                case detail(T)
            }
            """,
            expandedSource: """
            enum GenericPathable<T> {
                case detail(T)
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E003] @CasePathable does not support generic enum declarations. Generic parameters cannot be propagated through the generated `CasePath` members. Consider separating generic cases into a non-generic wrapper enum.",
                    line: 2,
                    column: 21
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("@Routable still expands non-generic enums normally")
    func testRoutableNonGenericBaseline() throws {
        assertMacroExpansion(
            """
            @Routable
            enum Plain {
                case home
            }
            """,
            expandedSource: """
            enum Plain {
                case home

                internal enum Cases {
                        internal static let home = CasePath<Plain, Void>(
                            embed: { _ in
                                .home
                            },
                            extract: {
                                if case .home = $0 {
                                    return ()
                                };
                                return nil
                            }
                        )
                }

                internal func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
                    casePath.extract(self) != nil
                }

                internal subscript <Value>(case casePath: CasePath<Self, Value>) -> Value? {
                    casePath.extract(self)
                }
            }

            extension Plain: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }
}

#endif
