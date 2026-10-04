// MARK: - RouterState+Codable.swift
// InnoRouterCore - explicit navigation state persistence formats
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

extension RouterPresentation: Codable where R: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case route
        case style
        case options
        case node
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        route = try container.decode(R.self, forKey: .route)
        style = try container.decode(RouterPresentationStyle.self, forKey: .style)
        options = try container.decodeIfPresent(
            RouterPresentationOptions.self,
            forKey: .options
        ) ?? .init()
        node = try container.decodeIfPresent(RouterNode<R>.self, forKey: .node) ?? .stack()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(route, forKey: .route)
        try container.encode(style, forKey: .style)
        if options != .init() {
            try container.encode(options, forKey: .options)
        }
        // Preserve the legacy leaf representation for an empty child stack.
        if node != .stack() {
            try container.encode(node, forKey: .node)
        }
    }
}

extension RouterStackState: Codable where R: Codable {
    private enum CodingKeys: String, CodingKey {
        case path, presentation, presentationFamily, alert, confirmationDialog
    }

    private enum FamilyKeys: String, CodingKey { case kind, descriptor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.alert), !container.contains(.confirmationDialog) else {
            throw RouterTransientPresentationPersistenceFailure.unsupportedRestoration
        }
        if container.contains(.presentationFamily) {
            guard RouterTransientDescriptorTransport.isEnabled(decoder.userInfo),
                  !container.contains(.presentation) else {
                throw RouterTransientPresentationPersistenceFailure.unsupportedRestoration
            }
            let family = try container.nestedContainer(keyedBy: FamilyKeys.self, forKey: .presentationFamily)
            let kind = try family.decode(RouterPresentationFamilyKind.self, forKey: .kind)
            // Navigation keeps its legacy field. No second spelling is admitted.
            guard kind != .navigation else {
                throw RouterTransientPresentationPersistenceFailure.unsupportedRestoration
            }
            let descriptor = try family.decode(RouterTransientPresentation.self, forKey: .descriptor)
            presentationFamily = kind == .alert ? .alert(descriptor) : .confirmationDialog(descriptor)
            path = try container.decode([R].self, forKey: .path)
        } else {
            path = try container.decode([R].self, forKey: .path)
            presentationFamily = try container.decodeIfPresent(RouterPresentation<R>.self, forKey: .presentation)
                .map(RouterPresentationFamily.navigation)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if let presentationFamily, presentationFamily.kind != .navigation,
           !RouterTransientDescriptorTransport.isEnabled(encoder.userInfo) {
            throw RouterTransientPresentationPersistenceFailure.transientPresent
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        switch presentationFamily {
        case .alert(let descriptor), .confirmationDialog(let descriptor):
            var family = container.nestedContainer(keyedBy: FamilyKeys.self, forKey: .presentationFamily)
            try family.encode(presentationFamily?.kind, forKey: .kind)
            try family.encode(descriptor, forKey: .descriptor)
        case .navigation, .none:
            try container.encodeIfPresent(presentation, forKey: .presentation)
        }
    }
}

extension RouterContainerStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum Kind: String, Codable {
        case tabs
        case split
        case custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tabs:
            self = .tabs
        case .split:
            self = .split
        case .custom:
            self = .custom(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tabs:
            try container.encode(Kind.tabs, forKey: .kind)
        case .split:
            try container.encode(Kind.split, forKey: .kind)
        case .custom(let name):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

extension RouterState: Codable where R: Codable {
    private enum CodingKeys: String, CodingKey {
        case root
        case windows
        case immersiveSpace
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(RouterNode<R>.self, forKey: .root)
        windows = try container.decode([RouterWindow<R>].self, forKey: .windows)
        immersiveSpace = try container.decodeIfPresent(
            RouterImmersiveSpace<R>.self,
            forKey: .immersiveSpace
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        if !RouterTransientDescriptorTransport.isEnabled(encoder.userInfo) {
            try rejectTransientPresentations(.transientPresent)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(immersiveSpace, forKey: .immersiveSpace)
    }
}
