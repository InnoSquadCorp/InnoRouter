import Foundation
import Testing

import InnoRouter
import InnoRouterTesting

private enum SequenceRoute: String, Route, Codable {
    case home
    case detail
    case settings
}

@Suite("Router action sequences")
struct RouterActionSequenceTests {
    @Test("Sequences encode deterministically and replay through production")
    @MainActor
    func deterministicReplay() async throws {
        let sequence = RouterActionSequence<SequenceRoute>(
            actions: [
                .push(.home),
                .pushMany([.detail, .settings]),
                .pop(count: 1),
                .replaceTop(.settings),
            ],
            context: .init(source: .inspector)
        )

        let first = try sequence.encoded()
        let second = try sequence.encoded()
        let decoded = try RouterActionSequence<SequenceRoute>.decode(first)
        let store = RouterTestStore<SequenceRoute>(exhaustivity: .off)

        let outcomes = await decoded.replay(on: store)

        #expect(first == second)
        #expect(decoded == sequence)
        #expect(outcomes.count == sequence.actions.count)
        #expect(store.state.root == .stack(path: [.home, .settings]))
        await store.finish()
    }

    @Test("Unknown sequence schemas fail before replay")
    func unknownSchema() throws {
        let data = Data(#"{"steps":[],"schemaVersion":2}"#.utf8)

        #expect(throws: DecodingError.self) {
            try RouterActionSequence<SequenceRoute>.decode(data)
        }
    }

    @Test("Replay preserves each step's policy-visible context and rejection")
    @MainActor
    func contextualReplay() async throws {
        let linkContext = RouterTransitionContext(
            source: .deepLink,
            animation: RouterAnimation.none,
            requestKey: "link",
            coalescing: .keepFirst
        )
        let intentContext = RouterTransitionContext(
            source: .appIntent,
            animation: .spring(duration: 0.3, bounce: 0.1),
            requestKey: "intent",
            coalescing: .replacePending,
            resumedDeferral: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        )
        let sequence = RouterActionSequence<SequenceRoute>(steps: [
            .init(action: .push(.home), context: linkContext),
            .init(action: .push(.detail), context: intentContext),
        ])
        let store = RouterTestStore<SequenceRoute>(
            configuration: .init(policies: [
                .init(name: "source") { transition in
                    transition.context.source == .appIntent ? .reject("intent denied") : .allow
                },
            ]),
            exhaustivity: .off
        )

        let decoded = try RouterActionSequence<SequenceRoute>.decode(sequence.encoded())
        let outcomes = await decoded.replay(on: store)
        let contexts = store.unassertedEvents.compactMap { event -> RouterTransitionContext? in
            guard case .started(let transition) = event else { return nil }
            return transition.context
        }

        #expect(decoded == sequence)
        #expect(contexts == [linkContext, intentContext])
        #expect(outcomes.count == 2)
        #expect(store.state.root == .stack(path: [.home]))
        #expect(store.unassertedEvents.contains { event in
            guard case .rejected(_, _, _, .policy(name: "source", message: "intent denied"), let context) = event else {
                return false
            }
            return context == intentContext
        })
        await store.finish()
    }

    @Test("Every production action remains Codable")
    func completeActionVocabulary() throws {
        let windowID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let actions: [RouterAction<SequenceRoute>] = [
            .push(.home),
            .pushIfNeeded(.home),
            .backOrPush(.detail),
            .replaceTop(.settings),
            .pushMany([.home, .detail]),
            .pop(count: 2),
            .popTo(.home),
            .popToRoot,
            .replaceStack([.settings]),
            .present(.init(route: .detail, style: .sheet)),
            .dismissPresentation,
            .setPresentationDetent(.medium),
            .select("home"),
            .setBadge(2, for: "home"),
            .clearAllBadges,
            .setSplitVisibility(.all),
            .setPreferredCompactColumn(.detail),
            .scoped("home", .push(.detail)),
            .windowScoped(windowID, .popToRoot),
            .immersiveSpaceScoped("studio", .push(.settings)),
            .openWindow(.init(id: windowID, route: .home)),
            .dismissWindow(windowID),
            .enterImmersiveSpace(.init(id: "studio", route: .detail)),
            .dismissImmersiveSpace,
            .apply(.init(state: .rootStack(path: [.home]))),
        ]
        let sequence = RouterActionSequence(actions: actions)

        #expect(
            try RouterActionSequence<SequenceRoute>.decode(sequence.encoded())
                == sequence
        )
    }
}
