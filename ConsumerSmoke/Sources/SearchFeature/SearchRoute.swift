import SwiftUI
import InnoRouter

@Router(
    deepLinkSchemes: ["search"],
    deepLinkHosts: ["search.example.com"],
    inspectorCatalog: true
)
public enum SearchRoute {
    case results(query: String)
    @DeepLink("/result/:id")
    case result(id: String)

    public var destination: some View {
        Text("Search")
    }
}

public struct SearchRoot: View {
    public init() {}
    public var body: some View { Text("Search root") }
}
