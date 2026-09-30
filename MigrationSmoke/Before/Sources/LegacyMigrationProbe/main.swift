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
private enum LegacyMigrationProbe {
    @MainActor
    static func main() throws {
        let store = NavigationStore<MigrationRoute>()
        _ = store.execute(.push(.home))
        _ = store.execute(.pushAll([.detail, .settings]))
        _ = store.execute(.popTo(.detail))
        _ = store.execute(.replace([.home, .settings]))

        let data = try JSONEncoder().encode(store.state.path)
        print(String(decoding: data, as: UTF8.self))
    }
}
