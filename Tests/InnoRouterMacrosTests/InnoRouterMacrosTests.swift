// MARK: - InnoRouterMacrosTests.swift
// InnoRouter Macros Tests
// Copyright © 2025 Inno Squad. All rights reserved.

// MARK: - Platform: InnoRouterMacrosPlugin is a host-only CompilerPlugin
// built for macOS. `@testable import` of the plugin's internals only
// succeeds on macOS, and the test body linker would otherwise pull a
// macOS-built object into non-macOS test binaries. Gate the whole file
// so non-macOS platforms compile an empty module; the meaningful macro
// tests are exercised by the macOS CI leg where they belong.
#if canImport(InnoRouterMacrosPlugin)

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@testable import InnoRouterMacrosPlugin

func makeTestMacros() -> [String: Macro.Type] {
    [
        "Router": RouterMacro.self,
        "DeepLink": DeepLinkMacro.self,
        "TabItem": TabItemMacro.self,
        "Routable": RoutableMacro.self,
        "CasePathable": CasePathableMacro.self,
    ]
}

// MARK: - Routable Macro Tests

@Suite("Routable Macro Tests")
struct RoutableMacroTests {
    @Test("Basic enum expansion")
    func testRoutableBasicEnum() throws {
        assertMacroExpansion(
            """
            @Routable
            enum HomeRoute {
                case home
                case settings
            }
            """,
            expandedSource: """
            enum HomeRoute {
                case home
                case settings

                internal enum Cases {
                        internal static let home = CasePath<HomeRoute, Void>(
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
                        internal static let settings = CasePath<HomeRoute, Void>(
                            embed: { _ in
                                .settings
                            },
                            extract: {
                                if case .settings = $0 {
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

            extension HomeRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Access level inference preserves enclosing enum visibility")
    func testRoutableAccessLevelInference() throws {
        assertMacroExpansion(
            """
            @Routable
            public enum PublicRoute {
                case home
            }
            """,
            expandedSource: """
            public enum PublicRoute {
                case home

                public enum Cases {
                        public static let home = CasePath<PublicRoute, Void>(
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

                public func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
                    casePath.extract(self) != nil
                }

                public subscript <Value>(case casePath: CasePath<Self, Value>) -> Value? {
                    casePath.extract(self)
                }
            }

            extension PublicRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )

        assertMacroExpansion(
            """
            @Routable
            fileprivate enum FilePrivateRoute {
                case home
            }
            """,
            expandedSource: """
            fileprivate enum FilePrivateRoute {
                case home

                fileprivate enum Cases {
                        fileprivate static let home = CasePath<FilePrivateRoute, Void>(
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

                fileprivate func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
                    casePath.extract(self) != nil
                }

                fileprivate subscript <Value>(case casePath: CasePath<Self, Value>) -> Value? {
                    casePath.extract(self)
                }
            }

            extension FilePrivateRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )

        assertMacroExpansion(
            """
            @Routable
            private enum PrivateRoute {
                case home
            }
            """,
            expandedSource: """
            private enum PrivateRoute {
                case home

                fileprivate enum Cases {
                        fileprivate static let home = CasePath<PrivateRoute, Void>(
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

                fileprivate func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
                    casePath.extract(self) != nil
                }

                fileprivate subscript <Value>(case casePath: CasePath<Self, Value>) -> Value? {
                    casePath.extract(self)
                }
            }

            extension PrivateRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )

        assertMacroExpansion(
            """
            @Routable
            package enum PackageRoute {
                case home
            }
            """,
            expandedSource: """
            package enum PackageRoute {
                case home

                package enum Cases {
                        package static let home = CasePath<PackageRoute, Void>(
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

                package func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
                    casePath.extract(self) != nil
                }

                package subscript <Value>(case casePath: CasePath<Self, Value>) -> Value? {
                    casePath.extract(self)
                }
            }

            extension PackageRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Case-level availability is copied to generated case paths")
    func testRoutableCopiesCaseAvailability() throws {
        assertMacroExpansion(
            """
            @Routable
            enum AvailabilityRoute {
                @available(iOS 19, *)
                case future
            }
            """,
            expandedSource: """
            enum AvailabilityRoute {
                @available(iOS 19, *)
                case future

                internal enum Cases {
                        @available(iOS 19, *)
                        internal static let future = CasePath<AvailabilityRoute, Void>(
                            embed: { _ in
                                .future
                            },
                            extract: {
                                if case .future = $0 {
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

            extension AvailabilityRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Escaped keyword cases expansion")
    func testRoutableWithEscapedKeywordCases() throws {
        assertMacroExpansion(
            """
            @Routable
            enum KeywordRoute {
                case `default`
                case `switch`(id: String)
            }
            """,
            expandedSource: """
            enum KeywordRoute {
                case `default`
                case `switch`(id: String)

                internal enum Cases {
                        internal static let `default` = CasePath<KeywordRoute, Void>(
                            embed: { _ in
                                .`default`
                            },
                            extract: {
                                if case .`default` = $0 {
                                    return ()
                                };
                                return nil
                            }
                        )
                        internal static let `switch` = CasePath<KeywordRoute, String>(
                            embed: { value in
                                .`switch`(id: value)
                            },
                            extract: {
                                if case .`switch`(let id) = $0 {
                                    return id
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

            extension KeywordRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Associated values expansion")
    func testRoutableWithAssociatedValues() throws {
        assertMacroExpansion(
            """
            @Routable
            enum ProductRoute {
                case list
                case detail(id: String)
            }
            """,
            expandedSource: """
            enum ProductRoute {
                case list
                case detail(id: String)

                internal enum Cases {
                        internal static let list = CasePath<ProductRoute, Void>(
                            embed: { _ in
                                .list
                            },
                            extract: {
                                if case .list = $0 {
                                    return ()
                                };
                                return nil
                            }
                        )
                        internal static let detail = CasePath<ProductRoute, String>(
                            embed: { value in
                                .detail(id: value)
                            },
                            extract: {
                                if case .detail(let id) = $0 {
                                    return id
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

            extension ProductRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Multiple associated values expansion")
    func testRoutableWithMultipleAssociatedValues() throws {
        assertMacroExpansion(
            """
            @Routable
            enum ProfileRoute {
                case main
                case edit(userId: String, section: Int)
            }
            """,
            expandedSource: """
            enum ProfileRoute {
                case main
                case edit(userId: String, section: Int)

                internal enum Cases {
                        internal static let main = CasePath<ProfileRoute, Void>(
                            embed: { _ in
                                .main
                            },
                            extract: {
                                if case .main = $0 {
                                    return ()
                                };
                                return nil
                            }
                        )
                        internal static let edit = CasePath<ProfileRoute, (String, Int)>(
                            embed: { value in
                                .edit(userId: value.0, section: value.1)
                            },
                            extract: {
                                if case .edit(let userId, let section) = $0 {
                                    return (userId, section)
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

            extension ProfileRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Underscore external label expansion")
    func testRoutableWithUnderscoreExternalLabel() throws {
        assertMacroExpansion(
            """
            @Routable
            enum DetailRoute {
                case detail(_ id: String)
            }
            """,
            expandedSource: """
            enum DetailRoute {
                case detail(_ id: String)

                internal enum Cases {
                        internal static let detail = CasePath<DetailRoute, String>(
                            embed: { value in
                                .detail(value)
                            },
                            extract: {
                                if case .detail(let id) = $0 {
                                    return id
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

            extension DetailRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Mixed labels expansion")
    func testRoutableWithMixedLabels() throws {
        assertMacroExpansion(
            """
            @Routable
            enum MixedRoute {
                case edit(_ id: String, section: Int)
            }
            """,
            expandedSource: """
            enum MixedRoute {
                case edit(_ id: String, section: Int)

                internal enum Cases {
                        internal static let edit = CasePath<MixedRoute, (String, Int)>(
                            embed: { value in
                                .edit(value.0, section: value.1)
                            },
                            extract: {
                                if case .edit(let id, let section) = $0 {
                                    return (id, section)
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

            extension MixedRoute: Route {
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Rejects non-enum declarations")
    func testRoutableOnlyAppliesToEnum() throws {
        assertMacroExpansion(
            """
            @Routable
            struct NotAnEnum {
            }
            """,
            expandedSource: """
            struct NotAnEnum {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E001] @Routable can only be applied to enum declarations",
                    line: 1,
                    column: 1,
                    fixIts: [FixItSpec(message: "Change `struct` to `enum`")]
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Errors when applied to an enum without cases")
    func testRoutableErrorsOnEmptyEnum() throws {
        assertMacroExpansion(
            """
            @Routable
            enum Empty {
            }
            """,
            expandedSource: """
            enum Empty {
            }

            extension Empty: Route {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E002] @Routable applied to an enum with no cases produces no case paths — consider adding at least one case or removing the macro",
                    line: 1,
                    column: 1,
                    severity: .error
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Does NOT error for an enum with at least one case")
    func testRoutableDoesNotErrorOnNonEmptyEnum() throws {
        assertMacroExpansion(
            """
            @Routable
            enum Populated {
                case home
            }
            """,
            expandedSource: """
            enum Populated {
                case home

                internal enum Cases {
                        internal static let home = CasePath<Populated, Void>(
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

            extension Populated: Route {
            }
            """,
            diagnostics: [],
            macros: makeTestMacros()
        )
    }
}

// MARK: - CasePathable Macro Tests

@Suite("CasePathable Macro Tests")
struct CasePathableMacroTests {
    @Test("Basic enum expansion")
    func testCasePathableBasicEnum() throws {
        assertMacroExpansion(
            """
            @CasePathable
            enum Destination {
                case home
                case profile(userId: String)
            }
            """,
            expandedSource: """
            enum Destination {
                case home
                case profile(userId: String)

                internal enum Cases {
                        internal static let home = CasePath<Destination, Void>(
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
                        internal static let profile = CasePath<Destination, String>(
                            embed: { value in
                                .profile(userId: value)
                            },
                            extract: {
                                if case .profile(let userId) = $0 {
                                    return userId
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
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Package enum expansion preserves package access")
    func testCasePathablePackageAccess() throws {
        assertMacroExpansion(
            """
            @CasePathable
            package enum Destination {
                case home
            }
            """,
            expandedSource: """
            package enum Destination {
                case home

                package enum Cases {
                        package static let home = CasePath<Destination, Void>(
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

                package func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
                    casePath.extract(self) != nil
                }

                package subscript <Value>(case casePath: CasePath<Self, Value>) -> Value? {
                    casePath.extract(self)
                }
            }
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Escaped keyword cases expansion")
    func testCasePathableWithEscapedKeywordCases() throws {
        assertMacroExpansion(
            """
            @CasePathable
            enum Destination {
                case `default`
                case `switch`(id: String)
            }
            """,
            expandedSource: """
            enum Destination {
                case `default`
                case `switch`(id: String)

                internal enum Cases {
                        internal static let `default` = CasePath<Destination, Void>(
                            embed: { _ in
                                .`default`
                            },
                            extract: {
                                if case .`default` = $0 {
                                    return ()
                                };
                                return nil
                            }
                        )
                        internal static let `switch` = CasePath<Destination, String>(
                            embed: { value in
                                .`switch`(id: value)
                            },
                            extract: {
                                if case .`switch`(let id) = $0 {
                                    return id
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
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Escaped keyword associated label expansion")
    func testCasePathableWithEscapedKeywordAssociatedLabel() throws {
        assertMacroExpansion(
            """
            @CasePathable
            enum Destination {
                case credential(`class`: String)
            }
            """,
            expandedSource: """
            enum Destination {
                case credential(`class`: String)

                internal enum Cases {
                        internal static let credential = CasePath<Destination, String>(
                            embed: { value in
                                .credential(`class`: value)
                            },
                            extract: {
                                if case .credential(let `class`) = $0 {
                                    return `class`
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
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Underscore external label expansion")
    func testCasePathableWithUnderscoreExternalLabel() throws {
        assertMacroExpansion(
            """
            @CasePathable
            enum Destination {
                case profile(_ userId: String)
            }
            """,
            expandedSource: """
            enum Destination {
                case profile(_ userId: String)

                internal enum Cases {
                        internal static let profile = CasePath<Destination, String>(
                            embed: { value in
                                .profile(value)
                            },
                            extract: {
                                if case .profile(let userId) = $0 {
                                    return userId
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
            """,
            macros: makeTestMacros()
        )
    }

    @Test("Rejects non-enum declarations")
    func testCasePathableOnlyAppliesToEnum() throws {
        assertMacroExpansion(
            """
            @CasePathable
            class NotAnEnum {
            }
            """,
            expandedSource: """
            class NotAnEnum {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E001] @CasePathable can only be applied to enum declarations",
                    line: 1,
                    column: 1,
                    fixIts: [FixItSpec(message: "Change `class` to `enum`")]
                )
            ],
            macros: makeTestMacros()
        )
    }

    @Test("Errors when applied to an enum without cases")
    func testCasePathableErrorsOnEmptyEnum() throws {
        assertMacroExpansion(
            """
            @CasePathable
            enum Empty {
            }
            """,
            expandedSource: """
            enum Empty {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "[InnoRouterMacro.E002] @CasePathable applied to an enum with no cases produces no case paths — consider adding at least one case or removing the macro",
                    line: 1,
                    column: 1,
                    severity: .error
                )
            ],
            macros: makeTestMacros()
        )
    }
}

#endif
