import Foundation
import SwiftUI

import InnoRouter

@Router
private enum MigrationRoute: String, Codable {
    case home
    case detail
    case settings

    var destination: some View {
        Text(rawValue)
    }
}

@main
private enum CanonicalMigrationProbe {
    @MainActor
    static func main() async throws {
        // The declaration remains macro-first. App-retained authority now uses
        // the one canonical store and action vocabulary generated for v6.
        let store = MigrationRoute.makeRouterStore()
        _ = await store.perform(.push(.home))
        _ = await store.perform(.pushMany([.detail, .settings]))
        _ = await store.perform(.popTo(.detail))
        _ = await store.perform(.replaceStack([.home, .settings]))

        guard case .stack(let stack) = store.state.root else {
            throw MigrationFailure.expectedRootStack
        }
        let data = try JSONEncoder().encode(stack.path)
        print(String(decoding: data, as: UTF8.self))
    }
}

private enum MigrationFailure: Error {
    case expectedRootStack
}
