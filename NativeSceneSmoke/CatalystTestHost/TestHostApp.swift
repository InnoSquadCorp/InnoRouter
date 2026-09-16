import SwiftUI

/// Provides the real UIKit/AppKit application lifetime required by Catalyst mount tests.
@main
struct RouterCatalystTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text(verbatim: "InnoRouter platform test host")
        }
    }
}
