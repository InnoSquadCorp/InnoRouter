/// Transient actions are never restored. Omission is an explicit encode-time
/// projection; it cannot reconstruct a waiter or permit transient input decode.
public enum RouterTransientPresentationPersistencePolicy: Sendable, Hashable {
    case reject, omit
}

/// Stable, payload-free persistence failures for transient UI.
public enum RouterTransientPresentationPersistenceFailure: String, Error, Sendable, Hashable, Codable {
    case transientPresent, unsupportedRestoration
}

import Foundation

package extension RouterState {
    /// Owners admit the complete source budget before calling this projection.
    /// Only transient leaves are removed; navigation identities are unchanged.
    func preparingTransientPersistence(_ policy: RouterTransientPresentationPersistencePolicy) throws -> Self {
        switch policy {
        case .reject:
            try rejectTransientPresentations(.transientPresent)
            return self
        case .omit:
            var copy = self
            copy.root = root.omittingTransientPresentations()
            copy.windows = windows.map { window in
                var copy = window
                copy.node = window.node.omittingTransientPresentations()
                return copy
            }
            copy.immersiveSpace = immersiveSpace.map { space in
                var copy = space
                copy.node = space.node.omittingTransientPresentations()
                return copy
            }
            return copy
        }
    }

    func rejectTransientPresentations(_ failure: RouterTransientPresentationPersistenceFailure) throws {
        var pending = [root] + windows.map(\.node)
        if let immersiveSpace { pending.append(immersiveSpace.node) }
        while let node = pending.popLast() {
            switch node {
            case .stack(let stack):
                switch stack.presentationFamily {
                case .none: break
                case .navigation(let presentation): pending.append(presentation.node)
                case .alert, .confirmationDialog: throw failure
                }
            case .container(let container): pending.append(contentsOf: container.branches.map(\.node))
            }
        }
    }
}

private extension RouterNode {
    func omittingTransientPresentations() -> Self {
        switch self {
        case .stack(var stack):
            switch stack.presentationFamily {
            case .navigation(var presentation):
                presentation.node = presentation.node.omittingTransientPresentations()
                stack.presentationFamily = .navigation(presentation)
            case .alert, .confirmationDialog: stack.presentationFamily = nil
            case .none: break
            }
            return .stack(stack)
        case .container(var container):
            container.branches = container.branches.map { branch in
                var copy = branch
                copy.node = branch.node.omittingTransientPresentations()
                return copy
            }
            return .container(container)
        }
    }
}

/// Typed migration convenience must reject constructed transient state before
/// JSONEncoder reaches an application's Route. This is not descriptor transport.
package protocol RouterTransientPersistenceChecking {
    static var transientMigrationStateKey: String? { get }
    func rejectTransientPersistence() throws
}

extension RouterState: RouterTransientPersistenceChecking {
    package static var transientMigrationStateKey: String? { nil }
    package func rejectTransientPersistence() throws {
        try rejectTransientPresentations(.unsupportedRestoration)
    }
}

extension RouterPlan: RouterTransientPersistenceChecking {
    package static var transientMigrationStateKey: String? { "state" }
    package func rejectTransientPersistence() throws {
        try state.rejectTransientPresentations(.unsupportedRestoration)
    }
}

/// Screens only library-owned presentation slots. App route objects are opaque:
/// an app is free to use fields such as `alert` in its own route payload.
/// Run after bounded JSON preflight, and before migrations or app route decode.
package enum RouterTransientRestorationScreen {
    package static func rejectReservedKeys(_ decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        if fields.contains(.presentationFamily) || fields.contains(.alert) || fields.contains(.confirmationDialog) {
            throw RouterTransientPresentationPersistenceFailure.unsupportedRestoration
        }
    }

    private enum Keys: String, CodingKey {
        case presentationFamily, alert, confirmationDialog
    }
}

/// Semantic-only inert pass when legacy callers explicitly disable limits.
/// No application Decodable implementation is invoked.
package struct RouterTransientOpaqueRoute: Route, Codable {
    package init(from decoder: any Decoder) throws {}
}
