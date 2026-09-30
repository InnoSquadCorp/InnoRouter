#if os(tvOS)
import Testing
import InnoRouterCore
import InnoRouterSwiftUI

private enum FocusRoute: Route {
    case grid
    case detail(Int)
}

@Suite("tvOS focus-driven navigation", .tags(.unit))
@MainActor
struct TvOSFocusNavigationTests {
    @Test("rapid focus push and pop stays synchronized")
    func rapidPushPop() async {
        let store = RouterStore<FocusRoute>()
        for index in 0..<20 {
            _ = await store.perform(.push(.detail(index)))
            #expect(store.state.root == .stack(path: [.detail(index)]))
            _ = await store.perform(.pop(count: 1))
            #expect(store.state.root == .stack())
        }
    }

    @Test("over-pop is rejected without changing focus history")
    func invalidPop() async {
        let store = RouterStore<FocusRoute>(initialPath: [.grid, .detail(1)])

        let result = await store.perform(.pop(count: 99))

        guard case .rejected(_, _, _, .mutation(.invalidPopCount(99, 2, .root))) = result else {
            Issue.record("Expected typed invalid pop rejection")
            return
        }
        #expect(store.state.root == .stack(path: [.grid, .detail(1)]))
    }
}
#endif
