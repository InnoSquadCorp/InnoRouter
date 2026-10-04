import Foundation
import Testing

import InnoRouter

@MainActor
private final class RouterDiagnosticRecorder: Sendable {
    var events: [RouterDiagnosticEvent] = []
}

@Suite("Router payload-safe observability")
struct RouterObservabilityTests {
    private enum SystemRoute: Route {
        case home
        case detail(String)
    }

    @Test("Observability emits structural events without route payloads")
    @MainActor
    func payloadSafeObservability() async throws {
        let recorder = RouterDiagnosticRecorder()
        let observability = RouterObservability<SystemRoute> { event in
            recorder.events.append(event)
        }
        let configuration = RouterStoreConfiguration<SystemRoute>()
            .observing(observability)
        let store = RouterStore<SystemRoute>(configuration: configuration)

        _ = await store.perform(.push(.detail("never-log-this")))
        _ = await store.perform(
            .pop(count: 0),
            context: .init(source: .appIntent)
        )
        _ = await store.perform(
            .pop(count: 99),
            context: .init(source: .system)
        )

        #expect(
            recorder.events.map(\.kind) == [
                .started,
                .committed,
                .unchanged,
                .rejectedMutation,
            ]
        )
        #expect(
            recorder.events.map(\.source) == [
                .application,
                .application,
                .appIntent,
                .system,
            ]
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(recorder.events),
            as: UTF8.self
        )
        #expect(!encoded.contains("never-log-this"))
    }

    @Test("Policy deferral is diagnostic information, not a rejection")
    @MainActor
    func deferredPolicyDiagnostic() async {
        let recorder = RouterDiagnosticRecorder()
        let deferralID = RouterDeferralID()
        let observability = RouterObservability<SystemRoute> { event in
            recorder.events.append(event)
        }
        let configuration = RouterStoreConfiguration<SystemRoute>(
            policies: [
                RouterPolicy(name: "approval") { _ in
                    .deferRequest(deferralID)
                }
            ]
        ).observing(observability)
        let store = RouterStore<SystemRoute>(configuration: configuration)

        _ = await store.perform(.push(.home))

        #expect(
            recorder.events.map(\.kind) == [
                .started,
                .policyDeferred,
                .deferred,
            ]
        )
        #expect(!recorder.events.map(\.kind).contains(.policyRejected))
    }

    @Test("Observability classifies every lifecycle and rejection without payloads")
    @MainActor
    func exhaustiveObservabilityClassification() throws {
        let first = RouterDiagnosticRecorder()
        let second = RouterDiagnosticRecorder()
        let combined = RouterObservability<SystemRoute>.combined([
            RouterObservability { first.events.append($0) },
            RouterObservability { second.events.append($0) },
        ])
        let id = RouterTransitionID()
        let deferralID = RouterDeferralID()
        let state = RouterState<SystemRoute>.rootStack
        let context = RouterTransitionContext(source: .inspector)
        let transition = RouterTransition(
            id: id,
            action: .push(.home),
            initialState: state,
            proposedState: .rootStack(path: [.home]),
            initialRevision: 7,
            context: context
        )
        let deferral = RouterDeferredTransition(
            id: deferralID,
            transitionID: id,
            policy: "approval",
            initialRevision: 7,
            source: .inspector
        )

        let lifecycle: [RouterEvent<SystemRoute>] = [
            .started(transition),
            .policyPrepared(transitionID: id, policy: "allow", decision: .allow),
            .policyPrepared(transitionID: id, policy: "reject", decision: .reject("denied")),
            .policyPrepared(transitionID: id, policy: "defer", decision: .deferRequest(deferralID)),
            .committed(
                transitionID: id,
                before: state,
                after: .rootStack(path: [.home]),
                revision: 8,
                context: context
            ),
            .unchanged(transitionID: id, state: state, revision: 8, context: context),
            .deferred(
                transitionID: id,
                state: state,
                revision: 8,
                deferral: deferral,
                context: context
            ),
            .platformAdapted(
                eventID: id,
                adaptation: .tabBadgeVisualUnavailable(scope: "home", count: 1),
                revision: 8
            ),
        ]
        for event in lifecycle {
            combined.record(event)
        }

        let reasons: [RouterRejectionReason] = [
            .mutation(.invalidPopCount(requested: 2, available: 0, scope: .root)),
            .policy(name: "gate", message: "denied"),
            .busy(activeTransition: RouterTransitionID()),
            .coalesced(existingTransition: RouterTransitionID()),
            .superseded(replacementTransition: RouterTransitionID()),
            .queueOverflow(limit: 2),
            .policyTimedOut(name: "slow"),
            .policyCapacityExceeded(limit: 2),
            .deferralConflict(deferralID),
            .deferralNotFound(deferralID),
            .deferralCapacityExceeded(limit: 1),
            .deferralExpired(deferralID),
            .deferralEvicted(deferralID),
            .staleState(expectedRevision: 1, actualRevision: 2),
            .cancelled,
            .missingAuthority(routeType: "SystemRoute"),
        ]
        for reason in reasons {
            combined.record(
                .rejected(
                    transitionID: id,
                    state: state,
                    revision: 8,
                    reason: reason,
                    context: context
                )
            )
        }

        let expectedKinds: [RouterDiagnosticEventKind] = [
            .started,
            .policyAllowed,
            .policyRejected,
            .policyDeferred,
            .committed,
            .unchanged,
            .deferred,
            .platformAdapted,
            .rejectedMutation,
            .rejectedPolicy,
            .rejectedBusy,
            .rejectedCoalesced,
            .rejectedSuperseded,
            .rejectedQueueOverflow,
            .rejectedPolicyTimeout,
            .rejectedPolicy,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedStaleState,
            .rejectedCancelled,
            .rejectedMissingAuthority,
        ]
        #expect(first.events.map(\.kind) == expectedKinds)
        #expect(second.events == first.events)
        #expect(first.events[1].policy == "allow")
        #expect(first.events[4].source == .inspector)
        #expect(first.events[4].revision == 8)

        let encoded = try JSONEncoder().encode(first.events)
        #expect(
            try JSONDecoder().decode([RouterDiagnosticEvent].self, from: encoded)
                == first.events
        )
    }

    @Test("Authorization and capacity diagnostics expose only structural metadata")
    @MainActor
    func authorizationAndCapacityRemainPayloadSafe() throws {
        let recorder = RouterDiagnosticRecorder()
        let observer = RouterObservability<SystemRoute> { recorder.events.append($0) }
        let id = RouterTransitionID()
        let state = RouterState<SystemRoute>.rootStack(path: [.detail("private-route-value")])
        let context = RouterTransitionContext(
            source: .deepLink,
            requestKey: "private-request-key"
        )
        let authorizationCodes: [RouterAuthorizationFailure.Code] = [
            .denied, .generationChanged, .unresolvedRoot, .timedOut,
            .capacityExceeded, .revalidationRequired, .intentChanged,
            .init(rawValue: "private-app-authorization-code"),
        ]
        let reasons: [RouterRejectionReason] = authorizationCodes.map {
            .authorization(.init(code: $0, limit: 17))
        } + [
            .policyCapacityExceeded(limit: 19),
            .deferralCapacityExceeded(limit: 23),
            .queueOverflow(limit: 29),
            .policy(name: "private-policy-name", message: "private-policy-message"),
        ]
        for reason in reasons {
            observer.record(
                .rejected(
                    transitionID: id,
                    state: state,
                    revision: 11,
                    reason: reason,
                    context: context
                )
            )
        }

        let expectedKinds = Array(
            repeating: RouterDiagnosticEventKind.rejectedPolicy,
            count: authorizationCodes.count
        ) + [.rejectedPolicy, .rejectedDeferral, .rejectedQueueOverflow, .rejectedPolicy]
        #expect(recorder.events.map(\.kind) == expectedKinds)
        #expect(recorder.events.allSatisfy {
            $0.transitionID == id && $0.revision == 11 && $0.source == .deepLink && $0.policy == nil
        })

        let encoded = try JSONEncoder().encode(recorder.events)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(!encodedText.contains("private-"))
        #expect(!encodedText.contains("authorization."))
        let objects = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let permittedKeys: Set<String> = ["kind", "transitionID", "source", "revision"]
        #expect(objects.count == reasons.count)
        #expect(objects.allSatisfy { Set($0.keys) == permittedKeys })
        #expect(
            try JSONDecoder().decode([RouterDiagnosticEvent].self, from: encoded)
                == recorder.events
        )
    }
}
