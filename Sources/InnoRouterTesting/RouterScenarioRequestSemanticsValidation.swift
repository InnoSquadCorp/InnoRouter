import InnoRouterCore

enum RouterScenarioRequestSemanticsValidator {
    static func validate<R: Route & Codable>(
        _ steps: [RouterScenarioStep<R>]
    ) throws {
        for step in steps {
            switch step.requestSemantics {
            case .action:
                break
            case .historyNavigation:
                guard step.context.source == .history,
                      case .apply = step.action else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
            case .featureAction(let scope, let lifetime, let features):
                guard valid(lifetime: lifetime, for: scope),
                      features.isEmpty == false,
                      Set(features.map(\.namespace)).count == features.count else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
            case .featurePlan(let scope, let lifetime, _, let features):
                guard case .apply = step.action,
                      valid(lifetime: lifetime, for: scope),
                      features.isEmpty == false,
                      Set(features.map(\.namespace)).count == features.count else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
            }
        }
    }

    private static func valid(
        lifetime: RouterScenarioSceneLifetime,
        for scope: RouterScopePath
    ) -> Bool {
        switch (scope.domain, lifetime) {
        case (.application, .application),
             (.window, .currentScene),
             (.window, .expiredScene),
             (.immersiveSpace, .currentScene),
             (.immersiveSpace, .expiredScene):
            true
        default:
            false
        }
    }
}
