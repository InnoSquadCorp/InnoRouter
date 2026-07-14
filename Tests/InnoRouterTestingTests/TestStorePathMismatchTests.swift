// MARK: - TestStorePathMismatchTests.swift
// InnoRouterTestingTests - onPathMismatch forwarding through NavigationTestStore
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterTesting

private enum MismatchRoute: Route {
    case root
    case other
    case unrelated
}

@Suite("TestStore Path Mismatch Tests")
struct TestStorePathMismatchTests {

    @Test("Non-prefix path binding rewrite emits .pathMismatch")
    @MainActor
    func nonPrefixRewriteEmitsPathMismatch() {
        let store = NavigationTestStore<MismatchRoute>()
        store.send(.go(.root))
        store.receiveChange()

        // SwiftUI rewrites pathBinding with a non-prefix value.
        store.store.pathBinding.wrappedValue = [.unrelated]

        // Expect a .pathMismatch followed by the resulting .changed event
        // (the default policy is .replace).
        store.receivePathMismatch { event in
            event.oldPath == [.root] && event.newPath == [.unrelated]
        }
        store.receiveChange { _, new in new.path == [.unrelated] }
        store.finish()
    }

    @Test("User-supplied onPathMismatch still fires (callback chaining preserved)")
    @MainActor
    func userOnPathMismatchIsPreserved() {
        let captured = Mutex<[NavigationPathMismatchEvent<MismatchRoute>]>([])
        let store = NavigationTestStore<MismatchRoute>(
            configuration: NavigationStoreConfiguration(
                onPathMismatch: { event in
                    captured.withLock { $0.append(event) }
                }
            )
        )

        store.send(.go(.root))
        store.receiveChange()

        store.store.pathBinding.wrappedValue = [.other]
        store.receivePathMismatch()
        store.receiveChange()
        store.finish()

        #expect(captured.withLock { $0.count } == 1)
    }
}
