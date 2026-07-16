// MARK: - TestStoreConfigurationPreservationTests.swift
// InnoRouterTestingTests - production configuration fidelity
// Copyright © 2026 Inno Squad. All rights reserved.

import Synchronization
import Testing

import InnoRouter
import InnoRouterSwiftUI
import InnoRouterTesting

private enum PreservedRoute: Route {
    case home
    case detail
    case sheetA
    case sheetB
}

@MainActor
private func cancelDismissAllMiddleware() -> AnyModalMiddleware<PreservedRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in
        if case .dismissAll = command {
            return .cancel(.conditionFailed)
        }
        return .proceed(command)
    })
}

@MainActor
private func cancelReplaceMiddleware() -> AnyNavigationMiddleware<PreservedRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in
        if case .replace = command {
            return .cancel(.conditionFailed)
        }
        return .proceed(command)
    })
}

@Suite("TestStore Configuration Preservation Tests")
@MainActor
struct TestStoreConfigurationPreservationTests {

    @Test("NavigationTestStore preserves observation and buffering")
    func navigationConfigurationIsPreserved() async {
        let observed = Mutex<[NavigationEvent<PreservedRoute>]>([])
        let store = NavigationTestStore<PreservedRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    observed.withLock { $0.append(event) }
                },
                eventBufferingPolicy: .bufferingNewest(1)
            )
        )
        var iterator = store.store.events.makeAsyncIterator()

        store.send(.go(.home))
        store.store.pathBinding.wrappedValue = [.home, .detail]

        #expect(observed.withLock { $0.count } == 2)

        guard case .changed(_, let finalState) = await iterator.next() else {
            Issue.record("Expected the newest navigation change event")
            return
        }
        #expect(finalState.path == [.home, .detail])

        store.skipReceivedEvents()
        store.finish()
    }

    @Test("ModalTestStore preserves replacement observation and queue policy")
    func modalConfigurationIsPreserved() async {
        let active = ModalPresentation<PreservedRoute>(route: .home, style: .sheet)
        let queued = ModalPresentation<PreservedRoute>(route: .sheetA, style: .sheet)
        let replacement = ModalPresentation<PreservedRoute>(route: .detail, style: .fullScreenCover)
        let replacements = Mutex<[(PreservedRoute, PreservedRoute)]>([])
        let store = ModalTestStore<PreservedRoute>(
            currentPresentation: active,
            queuedPresentations: [queued],
            configuration: ModalStoreConfiguration(
                middlewares: [
                    ModalMiddlewareRegistration(
                        middleware: cancelDismissAllMiddleware(),
                        debugName: "cancel-dismiss-all"
                    ),
                ],
                onEvent: { event in
                    guard case .replaced(let old, let new) = event else { return }
                    replacements.withLock { $0.append((old.route, new.route)) }
                },
                eventBufferingPolicy: .bufferingNewest(1),
                queueCancellationPolicy: .dropQueued
            )
        )
        var iterator = store.store.events.makeAsyncIterator()

        _ = store.execute(.replaceCurrent(replacement))
        _ = store.execute(.dismissAll)

        #expect(replacements.withLock { $0.count } == 1)
        #expect(replacements.withLock { $0.first?.0 } == .home)
        #expect(replacements.withLock { $0.first?.1 } == .detail)
        #expect(store.currentPresentation == replacement)
        #expect(store.queuedPresentations.isEmpty)
        #expect(store.unassertedEvents.contains { event in
            guard case .replaced(let old, let new) = event else { return false }
            return old == active && new == replacement
        })
        guard
            case .commandIntercepted(command: .dismissAll, result: .cancelled) = await iterator.next()
        else {
            Issue.record("Expected the newest modal cancellation event")
            return
        }

        store.skipReceivedEvents()
        store.finish()
    }

    @Test("FlowTestStore preserves top-level observation, buffering, and coalescing")
    func flowConfigurationIsPreserved() async {
        let callbackEvents = Mutex<[FlowEvent<PreservedRoute>]>([])
        let store = FlowTestStore<PreservedRoute>(
            configuration: FlowStoreConfiguration(
                navigation: NavigationStoreConfiguration(
                    middlewares: [
                        NavigationMiddlewareRegistration(
                            middleware: cancelReplaceMiddleware(),
                            debugName: "cancel-replace"
                        ),
                    ]
                ),
                onEvent: { event in
                    callbackEvents.withLock { $0.append(event) }
                },
                eventBufferingPolicy: .bufferingNewest(1),
                queueCoalescePolicy: .dropQueued
            )
        )
        var iterator = store.store.events.makeAsyncIterator()

        store.send(.presentSheet(.sheetA))
        store.send(.presentSheet(.sheetB))
        store.send(.replaceStack([.home]))

        #expect(store.path.isEmpty)
        #expect(callbackEvents.withLock { events in
            events.contains { event in
                if case .intentRejected = event { return true }
                return false
            }
        })
        guard case .intentRejected(.replaceStack([.home]), _) = await iterator.next() else {
            Issue.record("Expected the newest flow rejection event")
            return
        }

        store.skipReceivedEvents()
        store.finish()
    }

    @Test("FlowTestStore preserves inner observers")
    func flowInnerConfigurationsArePreserved() {
        let navigationEvents = Mutex<[NavigationEvent<PreservedRoute>]>([])
        let modalEvents = Mutex<[ModalEvent<PreservedRoute>]>([])
        let store = FlowTestStore<PreservedRoute>(
            configuration: FlowStoreConfiguration(
                navigation: NavigationStoreConfiguration(
                    onEvent: { event in
                        navigationEvents.withLock { $0.append(event) }
                    }
                ),
                modal: ModalStoreConfiguration(
                    onEvent: { event in
                        modalEvents.withLock { $0.append(event) }
                    }
                )
            )
        )

        store.send(.push(.home))
        store.send(.presentSheet(.sheetA))

        #expect(store.path == [.push(.home), .sheet(.sheetA)])
        #expect(navigationEvents.withLock { events in
            events.contains { event in
                if case .changed = event { return true }
                return false
            }
        })
        #expect(modalEvents.withLock { events in
            events.contains { event in
                if case .presented = event { return true }
                return false
            }
        })

        store.skipReceivedEvents()
        store.finish()
    }
}
