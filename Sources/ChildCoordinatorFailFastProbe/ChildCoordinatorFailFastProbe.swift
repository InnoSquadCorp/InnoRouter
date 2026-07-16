import InnoRouterSwiftUI

@MainActor
private final class ProbeChild: ChildCoordinator {
    typealias Result = String

    var onFinish: (@MainActor @Sendable (String) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?
}

@MainActor
@main
struct ChildCoordinatorFailFastProbe {
    static func main() async {
        let child = ProbeChild()

        let firstWait = Task { @MainActor in
            await child.waitForResult()
        }
        while child.onFinish == nil || child.onCancel == nil {
            await Task.yield()
        }

        _ = await child.waitForResult()
        firstWait.cancel()
    }
}
