import SwiftUI
import InnoRouter

@Router(
    deepLinkSchemes: ["account"],
    deepLinkHosts: ["account.example.com"],
    inspectorCatalog: true
)
public enum AccountRoute {
    case overview
    @DeepLink("/profile/:userID")
    case profile(userID: String)

    public var destination: some View {
        Text("Account")
    }
}

public struct AccountRoot: View {
    public init() {}
    public var body: some View { Text("Account root") }
}
