import Foundation

/// The mutually exclusive presentation owned by one stack. Only navigation
/// presentations own a child navigation node.
public enum RouterPresentationFamily<R: Route>: Hashable, Sendable {
    case navigation(RouterPresentation<R>)
    case alert(RouterTransientPresentation)
    case confirmationDialog(RouterTransientPresentation)

    public var id: UUID {
        switch self {
        case .navigation(let value): value.id
        case .alert(let value), .confirmationDialog(let value): value.id
        }
    }

    public var kind: RouterPresentationFamilyKind {
        switch self {
        case .navigation: .navigation
        case .alert: .alert
        case .confirmationDialog: .confirmationDialog
        }
    }
}

public enum RouterPresentationFamilyKind: String, Hashable, Sendable, Codable {
    case navigation, alert, confirmationDialog
}

/// A declaration identifier, never a result value or executable action.
public struct RouterPresentationActionID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public enum RouterPresentationActionRole: String, Hashable, Sendable, Codable {
    case normal, cancel, destructive
}

public struct RouterPresentationActionDescriptor: Hashable, Sendable, Codable {
    public let id: RouterPresentationActionID
    public let label: String
    public let role: RouterPresentationActionRole

    public init(id: RouterPresentationActionID, label: String, role: RouterPresentationActionRole = .normal) {
        self.id = id
        self.label = label
        self.role = role
    }
}

/// Immutable display metadata. Typed results and callbacks never enter state.
public struct RouterTransientPresentationContent: Hashable, Sendable, Codable {
    public let title: String
    public let message: String?
    public let actions: [RouterPresentationActionDescriptor]

    public init(title: String, message: String? = nil, actions: [RouterPresentationActionDescriptor]) {
        self.title = title
        self.message = message
        self.actions = actions
    }
}

public struct RouterTransientPresentation: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let content: RouterTransientPresentationContent

    public init(id: UUID = UUID(), content: RouterTransientPresentationContent) {
        self.id = id
        self.content = content
    }

    /// Descriptor transport requires an explicit bounded Testing owner. Bare
    /// Codable actions cannot accidentally become restoration payloads.
    public init(from decoder: any Decoder) throws {
        throw RouterTransientPresentationPersistenceFailure.unsupportedRestoration
    }

    public func encode(to encoder: any Encoder) throws {
        throw RouterTransientPresentationPersistenceFailure.transientPresent
    }
}

/// Payload-free structural failures. Admission must bound metadata before this
/// validation hashes action identifiers.
public enum RouterTransientPresentationValidationFailure: String, Error, Hashable, Sendable, Codable {
    case emptyActions, emptyActionID, duplicateActionID, multipleCancelActions
}

package extension RouterTransientPresentationContent {
    func validate() throws {
        guard !actions.isEmpty else {
            throw RouterStateValidationError.invalidTransientPresentation(.emptyActions)
        }
        var ids = Set<RouterPresentationActionID>()
        var hasCancel = false
        for action in actions {
            guard !action.id.rawValue.isEmpty else {
                throw RouterStateValidationError.invalidTransientPresentation(.emptyActionID)
            }
            guard ids.insert(action.id).inserted else {
                throw RouterStateValidationError.invalidTransientPresentation(.duplicateActionID)
            }
            if action.role == .cancel {
                guard !hasCancel else {
                    throw RouterStateValidationError.invalidTransientPresentation(.multipleCancelActions)
                }
                hasCancel = true
            }
        }
    }
}
