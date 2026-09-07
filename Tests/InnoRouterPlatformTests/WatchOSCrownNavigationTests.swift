#if os(watchOS)
import Testing
import InnoRouterCore
import InnoRouterSwiftUI

private enum CrownRoute: Route {
    case workouts
    case workout(Int)
}

@Suite("watchOS Digital Crown navigation", .tags(.unit))
@MainActor
struct WatchOSCrownNavigationTests {
    @Test("dense crown navigation preserves exact stack depth")
    func densePush() async {
        let store = RouterStore<CrownRoute>(initialPath: [.workouts])
        for index in 0..<32 {
            _ = await store.perform(.push(.workout(index)))
            guard case .stack(let stack) = store.state.root else { return }
            #expect(stack.path.count == index + 2)
        }
    }

    @Test("crown over-scroll stays at root and reports rejection")
    func overscrollPastRoot() async {
        let store = RouterStore<CrownRoute>()
        for _ in 0..<4 {
            let result = await store.perform(.pop(count: 1))
            guard case .rejected(_, _, _, .mutation(.invalidPopCount(1, 0, .root))) = result else {
                Issue.record("Expected typed root over-scroll rejection")
                return
            }
            #expect(store.state.root == .stack())
        }
    }
}
#endif
