/// A typed value associated with one declared button. Values remain ephemeral
/// and the router never invokes them, including when Value is a callable type.
public struct RouterPresentationAction<Value: Sendable>: Sendable {
    public let descriptor: RouterPresentationActionDescriptor
    public let value: Value

    public init(id: RouterPresentationActionID, label: String, role: RouterPresentationActionRole = .normal, value: Value) {
        descriptor = .init(id: id, label: label, role: role)
        self.value = value
    }
}

public enum RouterTransientPresentationKind: String, Hashable, Sendable {
    case alert, confirmationDialog
}

/// Reusable declaration. Every Store invocation gets a fresh logical identity
/// and completion owner. Neither request nor typed Value is persisted.
public struct RouterTransientPresentationRequest<Value: Sendable>: Sendable {
    public let kind: RouterTransientPresentationKind
    public let title: String
    public let message: String?
    public let actions: [RouterPresentationAction<Value>]

    public init(kind: RouterTransientPresentationKind, title: String, message: String? = nil, actions: [RouterPresentationAction<Value>]) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }

    public static func alert(title: String, message: String? = nil, actions: [RouterPresentationAction<Value>]) -> Self {
        .init(kind: .alert, title: title, message: message, actions: actions)
    }

    public static func confirmationDialog(title: String, message: String? = nil, actions: [RouterPresentationAction<Value>]) -> Self {
        .init(kind: .confirmationDialog, title: title, message: message, actions: actions)
    }
}
