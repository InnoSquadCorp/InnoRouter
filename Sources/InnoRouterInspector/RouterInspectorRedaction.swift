import InnoRouterCore
import InnoRouterSwiftUI

func redactedRouterFormatter<R: Route>() -> RouterInspectorFormatter<RouterEvent<R>> {
    RouterInspectorFormatter { event in
        switch event {
        case .started(let transition):
            return .init(
                name: "transition.started",
                metadata: [
                    "action": transition.action.inspectorName,
                    "source": transition.context.source.rawValue,
                    "revision": "\(transition.initialRevision)",
                    "transitionID": transition.id.description,
                ],
                state: RouterInspectorProjection.tree(from: transition.initialState),
                replay: RouterInspectorReplay.preview(transition)
            )
        case .policyPrepared(let id, let policy, let decision):
            let outcome: RouterInspectorOutcome
            let decisionName: String
            switch decision {
            case .allow:
                outcome = .accepted
                decisionName = "allow"
            case .reject:
                outcome = .rejected
                decisionName = "reject"
            case .deferRequest:
                outcome = .informational
                decisionName = "defer"
            }
            return .init(
                name: "policy.prepared",
                outcome: outcome,
                metadata: [
                    "decision": decisionName,
                    "policy": policy,
                    "transitionID": id.description,
                ]
            )
        case .committed(let id, let before, let after, let revision, let context):
            return .init(
                name: "transition.committed",
                outcome: .accepted,
                metadata: [
                    "before": before.inspectorSummary,
                    "after": after.inspectorSummary,
                    "revision": "\(revision)",
                    "source": context.source.rawValue,
                    "transitionID": id.description,
                ],
                state: RouterInspectorProjection.tree(from: after),
                diff: RouterInspectorProjection.diff(from: before, to: after)
            )
        case .unchanged(let id, let state, let revision, let context):
            return .init(
                name: "transition.unchanged",
                metadata: [
                    "state": state.inspectorSummary,
                    "revision": "\(revision)",
                    "source": context.source.rawValue,
                    "transitionID": id.description,
                ],
                state: RouterInspectorProjection.tree(from: state)
            )
        case .deferred(let id, let state, let revision, let deferral, let context):
            return .init(
                name: "transition.deferred",
                metadata: [
                    "deferralID": deferral.id.description,
                    "policy": deferral.policy,
                    "revision": "\(revision)",
                    "source": context.source.rawValue,
                    "transitionID": id.description,
                ],
                state: RouterInspectorProjection.tree(from: state)
            )
        case .rejected(let id, let state, let revision, let reason, let context):
            return .init(
                name: "transition.rejected",
                outcome: .rejected,
                metadata: [
                    "reason": reason.inspectorName,
                    "revision": "\(revision)",
                    "source": context.source.rawValue,
                    "transitionID": id.description,
                ],
                state: RouterInspectorProjection.tree(from: state)
            )
        case .platformAdapted(let id, let adaptation, let revision):
            return .init(
                name: "platform.adapted",
                metadata: [
                    "adaptation": adaptation.inspectorName,
                    "eventID": id.description,
                    "revision": "\(revision)",
                ]
            )
        }
    }
}

private extension RouterPlatformAdaptation {
    var inspectorName: String {
        switch self {
        case .presentationStyle(_, let requested, let effective):
            "presentation.style.\(requested.rawValue).to.\(effective.rawValue)"
        case .presentationOptionsIgnored(_, let options):
            "presentation.options.ignored.\(options.map(\.rawValue).joined(separator: "."))"
        case .tabBadgeVisualUnavailable:
            "tab.badge.visualUnavailable"
        }
    }
}

private extension RouterAction {
    var inspectorName: String {
        switch self {
        case .push: "push"
        case .pushIfNeeded: "pushIfNeeded"
        case .backOrPush: "backOrPush"
        case .replaceTop: "replaceTop"
        case .pushMany: "pushMany"
        case .pop: "pop"
        case .popTo: "popTo"
        case .popToRoot: "popToRoot"
        case .replaceStack: "replaceStack"
        case .present: "present"
        case .dismissPresentation: "dismissPresentation"
        case .setPresentationDetent: "setPresentationDetent"
        case .select: "select"
        case .setBadge: "setBadge"
        case .clearAllBadges: "clearAllBadges"
        case .setSplitVisibility: "setSplitVisibility"
        case .setPreferredCompactColumn: "setPreferredCompactColumn"
        case .scoped(_, let action): "scoped.\(action.inspectorName)"
        case .windowScoped(_, let action): "windowScoped.\(action.inspectorName)"
        case .immersiveSpaceScoped(_, let action):
            "immersiveSpaceScoped.\(action.inspectorName)"
        case .openWindow: "openWindow"
        case .dismissWindow: "dismissWindow"
        case .enterImmersiveSpace: "enterImmersiveSpace"
        case .dismissImmersiveSpace: "dismissImmersiveSpace"
        case .apply: "apply"
        }
    }
}

private extension RouterState {
    var inspectorSummary: String {
        var stackCount = 0
        var routeCount = 0
        var presentationCount = 0
        func visit(_ node: RouterNode<R>) {
            switch node {
            case .stack(let stack):
                stackCount += 1
                routeCount += stack.path.count
                presentationCount += stack.presentation == nil ? 0 : 1
            case .container(let container):
                for branch in container.branches {
                    visit(branch.node)
                }
            }
        }
        visit(root)
        for window in windows {
            visit(window.node)
        }
        if let immersiveSpace {
            visit(immersiveSpace.node)
        }
        return "stacks=\(stackCount),routes=\(routeCount),presentations=\(presentationCount),windows=\(windows.count),immersive=\(immersiveSpace == nil ? 0 : 1)"
    }
}

private extension RouterRejectionReason {
    var inspectorName: String {
        switch self {
        case .mutation: "mutation"
        case .featureProjection: "feature-projection"
        case .policy: "policy"
        case .busy: "busy"
        case .coalesced: "coalesced"
        case .superseded: "superseded"
        case .queueOverflow: "queueOverflow"
        case .policyTimedOut: "policyTimedOut"
        case .deferralConflict: "deferralConflict"
        case .deferralNotFound: "deferralNotFound"
        case .deferralCapacityExceeded: "deferralCapacityExceeded"
        case .deferralExpired: "deferralExpired"
        case .deferralEvicted: "deferralEvicted"
        case .staleState: "staleState"
        case .cancelled: "cancelled"
        case .missingAuthority: "missingAuthority"
        }
    }
}
