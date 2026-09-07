// MARK: - PlatformHostingAdapters.swift
// InnoRouterSwiftUI - incremental UIKit/AppKit adoption
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouterCore

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Creates SwiftUI router hosts for an existing UIKit lifecycle.
///
/// The application retains the returned controller and installs it with normal
/// UIKit containment. Navigation remains owned by the supplied `RouterStore`;
/// this bridge does not mirror stacks into a second `UINavigationController`.
public enum RouterUIKitBridge {
    @MainActor
    public static func hostingController<R: DestinationRoute, Root: View>(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) -> UIViewController {
        UIHostingController(
            rootView: RouterHost(
                store: store,
                linkHandling: linkHandling,
                root: root
            )
        )
    }

    /// Installs a router hosting controller using correct UIKit containment.
    @MainActor
    @discardableResult
    public static func embed(
        _ child: UIViewController,
        in parent: UIViewController
    ) -> UIViewController {
        if child.parent === parent { return child }
        if child.parent != nil {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
        ])
        child.didMove(toParent: parent)
        return child
    }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Creates SwiftUI router hosts for an existing AppKit lifecycle.
///
/// Both factories retain the exact `RouterStore` supplied by the application,
/// preserving one navigation authority while AppKit continues to own its
/// window and controller lifecycle.
public enum RouterAppKitBridge {
    @MainActor
    public static func hostingController<R: DestinationRoute, Root: View>(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) -> NSViewController {
        NSHostingController(
            rootView: RouterHost(
                store: store,
                linkHandling: linkHandling,
                root: root
            )
        )
    }

    @MainActor
    public static func hostingView<R: DestinationRoute, Root: View>(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) -> NSView {
        NSHostingView(
            rootView: RouterHost(
                store: store,
                linkHandling: linkHandling,
                root: root
            )
        )
    }
}
#endif
