import InnoRouterCore

#if canImport(SwiftUI)
import SwiftUI
#endif

/// The only native animation boundary needed by the canonical Store engine.
/// Non-SwiftUI execution performs the same state assignment without simulating UI.
@MainActor
enum RouterNativeTransaction {
    static func commit(animation: RouterAnimation?, body: () -> Void) {
#if canImport(SwiftUI)
        switch animation {
        case nil:
            body()
        case .some(.none):
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { body() }
        case .default:
            withAnimation { body() }
        case .easeInOut(let duration):
            withAnimation(.easeInOut(duration: max(0, duration))) {
                body()
            }
        case .spring(let duration, let bounce):
            withAnimation(
                .spring(
                    duration: max(0.01, duration),
                    bounce: min(max(0, bounce), 1)
                )
            ) {
                body()
            }
        }
#else
        body()
#endif
    }
}
