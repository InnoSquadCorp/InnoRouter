#if canImport(InnoRouterMacrosPlugin)
import SwiftParser
import SwiftSyntax
import Testing

@testable import InnoRouterMacrosPlugin

/// W008 exists to explain one compiler error. It must not warn on code that
/// compiled before the warning existed, because a client that builds with
/// warnings as errors cannot downgrade a macro diagnostic.
@Suite("Shadowed SwiftUI Tab finder")
struct RouterShadowedTabFinderTests {
    /// Line numbers (1-based) of the calls the finder reports in `source`,
    /// whose first declaration must be the router enum.
    private func flaggedLines(_ source: String) throws -> [Int] {
        let file = Parser.parse(source: source)
        let enumDecl = try #require(file.statements.first?.item.as(EnumDeclSyntax.self))
        let converter = SourceLocationConverter(fileName: "Router.swift", tree: file)
        return ShadowedSwiftUITabCallFinder.references(in: enumDecl).map {
            $0.startLocation(converter: converter).line
        }
    }

    @Test("Every SwiftUI Tab initializer shape is reported")
    func swiftUIShapes() throws {
        #expect(try flaggedLines("""
        enum AppRoute {
            var a: some View { TabView { Tab("Home", systemImage: "house") { EmptyView() } } }
            var b: some View { TabView { Tab(value: 1) { EmptyView() } label: { Text("x") } } }
            var c: some View { TabView { Tab { EmptyView() } label: { Text("x") } } }
            var d: some View { TabView { Tab("Home", image: "house", content: makeHome) } }
            var e: some View { TabView { Tab(role: .search) { EmptyView() } } }
        }
        """) == [2, 3, 4, 5, 6])
    }

    @Test("Uses of the generated type are not reported")
    func generatedTypeUses() throws {
        #expect(try flaggedLines("""
        enum AppRoute {
            static let a = Tab(rawValue: "home")
            static let b = Tab.home
            static let c = Tab.allCases
            static func tab(for scope: RouterScopeID) -> Tab? { Tab(scope: scope) }
            static let d = Self.Tab(scope: "home")
            static let e = [Tab](repeating: .home, count: 2)
        }
        """).isEmpty)
    }

    @Test("A nested type that rebinds Tab is not searched")
    func nestedRebinding() throws {
        #expect(try flaggedLines("""
        enum AppRoute {
            struct Aliased {
                typealias Tab = SwiftUI.Tab
                var body: some View { TabView { Tab("a", systemImage: "b") { EmptyView() } } }
            }
            struct Declares {
                struct Tab { init(_ title: String, content: () -> Void) {} }
                static let value = Tab("a") {}
            }
            struct Plain {
                var body: some View { TabView { Tab("a", systemImage: "b") { EmptyView() } } }
            }
        }
        """) == [11])
    }

    @Test("A body that rebinds Tab locally is not searched")
    func localRebinding() throws {
        #expect(try flaggedLines("""
        enum AppRoute {
            func make() -> some View {
                typealias Tab = SwiftUI.Tab
                return TabView { Tab("a", systemImage: "b") { EmptyView() } }
            }
            var computed: some View {
                typealias Tab = SwiftUI.Tab
                return TabView { Tab("a", systemImage: "b") { EmptyView() } }
            }
            var closure: some View {
                build {
                    struct Tab { init(_ title: String, content: () -> Void) {} }
                    _ = Tab("a") {}
                }
            }
            func plain() -> some View { TabView { Tab("a", systemImage: "b") { EmptyView() } } }
        }
        """) == [16])
    }

    @Test("A nested tab router is recognised through a qualified attribute")
    func qualifiedTabItemAttribute() throws {
        #expect(try flaggedLines("""
        enum Outer {
            @Router
            enum Inner {
                @InnoRouterMacros.TabItem("B", systemImage: "b")
                case b
                var destination: some View { TabView { Tab("x", systemImage: "y") { EmptyView() } } }
            }
        }
        """).isEmpty)
    }

    @Test("A nested tab router reports its own calls")
    func nestedTabRouter() throws {
        let source = """
        enum Outer {
            @TabItem("A", systemImage: "a")
            case a
            @Router
            enum Inner {
                @TabItem("B", systemImage: "b")
                case b
                var destination: some View { TabView { Tab("x", systemImage: "y") { EmptyView() } } }
            }
            @Router
            enum Plain {
                case c
                var destination: some View { TabView { Tab("x", systemImage: "y") { EmptyView() } } }
            }
        }
        """
        // `Inner` generates its own `Tab`; `Plain` does not, so inside it the
        // name still means `Outer.Tab`.
        #expect(try flaggedLines(source) == [13])
    }
}
#endif
