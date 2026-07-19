import OSLog

import InnoRouterCore

private let navigationStoreReentrancyLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "navigation-reentrancy"
)

extension NavigationStore {
    private static var reentrantMiddlewareMessage: String {
        "Navigation execution was rejected because middleware callbacks cannot synchronously re-enter the same store."
    }

    func reentrantMiddlewareRejection(
        operation: StaticString
    ) -> NavigationResult<R>? {
        guard middlewareRegistry.isInvokingCallback else {
            return nil
        }

        navigationStoreReentrancyLogger.warning(
            """
            Reentrant navigation execution rejected. \
            operation=\(String(describing: operation), privacy: .public) \
            route=\(String(reflecting: R.self), privacy: .private(mask: .hash))
            """
        )
        return .cancelled(.custom(Self.reentrantMiddlewareMessage))
    }
}
