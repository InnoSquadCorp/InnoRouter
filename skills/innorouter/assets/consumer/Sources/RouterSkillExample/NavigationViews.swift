import SwiftUI
import InnoRouter

public struct StackRoot: View {
    public init() {}
    public var body: some View {
        RouterHost(AppRoute.self) { NavigationActions() }
    }
}

private struct NavigationActions: View {
    @EnvironmentRouter(AppRoute.self) private var router
    @EnvironmentRouterState(AppRoute.self) private var state

    var body: some View {
        Button("Product") { router.go(.product(id: "42")) }
            .disabled(state.presentationFamily != nil)
    }
}

public struct TabsRoot: View {
    private let setup: Result<RouterTabHost<AppRoute>, Error>

    public init() {
        do { setup = .success(try RouterTabHost(AppRoute.self, initial: .home)) }
        catch { setup = .failure(error) }
    }

    public var body: some View {
        switch setup {
        case .success(let host): host
        case .failure:
            ContentUnavailableView("Navigation unavailable", systemImage: "exclamationmark.triangle")
        }
    }
}
