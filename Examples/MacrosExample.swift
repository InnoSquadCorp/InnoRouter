import SwiftUI

import InnoRouter

// MARK: - Shared route declaration

@Router(
    deepLinkSchemes: ["example"],
    deepLinkHosts: ["router"]
)
enum MacroFirstRoute {
    @DeepLink("/products/:id")
    case product(id: String)

    @PresentationResult(Bool.self)
    case settings

    @Scene(.window, id: "editor")
    case editor

    var destination: some View {
        switch self {
        case .product(let id):
            Text("Product \(id)")
        case .settings:
            MacroFirstSettingsDestination()
        case .editor:
            Text("Editor")
        }
    }
}

// MARK: - Stack and presentation

struct MacroFirstStackExample: View {
    var body: some View {
        // Matching onOpenURL values are resolved and pushed automatically.
        RouterHost(MacroFirstRoute.self) {
            MacroFirstStackActions()
        }
    }
}

private struct MacroFirstStackActions: View {
    @EnvironmentRouter(MacroFirstRoute.self) private var router

    var body: some View {
        List {
            Button("Open product") {
                router.go(.product(id: "42"))
            }
            Button("Present settings") {
                Task {
                    _ = await router.present(MacroFirstRoute.Presentation.settings)
                }
            }
        }
        .navigationTitle("Products")
    }
}

private struct MacroFirstSettingsDestination: View {
    @EnvironmentRouter(MacroFirstRoute.self) private var router

    var body: some View {
        VStack {
            Text("Settings")
            Button("Dismiss") {
                Task {
                    try? await router.finishPresentation(
                        MacroFirstRoute.Presentation.settings,
                        returning: true
                    )
                }
            }
        }
    }
}

// MARK: - Split detail

#if !os(watchOS)
struct MacroFirstSplitExample: View {
    var body: some View {
        RouterSplitHost(MacroFirstRoute.self) {
            MacroFirstSplitSidebar()
        } root: {
            Text("Select a product")
        }
    }
}

private struct MacroFirstSplitSidebar: View {
    @EnvironmentRouter(MacroFirstRoute.self) private var router

    var body: some View {
        List {
            Button("Product 42") {
                router.go(.product(id: "42"))
            }
            Button("Settings sheet") {
                router.sheet(.settings)
            }
        }
        .navigationTitle("Catalog")
    }
}
#endif

// MARK: - Native tabs

@Router
enum MacroFirstTab {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    case settings

    var destination: some View {
        switch self {
        case .home:
            MacroFirstTabActions()
        case .settings:
            Text("Settings")
        }
    }
}

struct MacroFirstTabsExample: View {
    var body: some View {
        RouterTabHost(MacroFirstTab.self, initial: .home)
    }
}

private struct MacroFirstTabActions: View {
    @EnvironmentRouter(MacroFirstTab.self) private var router

    var body: some View {
        VStack {
            Button("Select settings") {
                router.select(.settings)
            }
            Button("Badge settings") {
                router.setBadge(1, for: .settings)
            }
        }
    }
}
