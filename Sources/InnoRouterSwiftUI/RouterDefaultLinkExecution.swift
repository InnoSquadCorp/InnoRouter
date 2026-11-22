// MARK: - RouterDefaultLinkExecution.swift
// InnoRouterSwiftUI - link execution for hosts without RouterLinkHandling
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import OSLog

import InnoRouterCore
import InnoRouterDeepLink

private let routerDefaultLinkLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "macro-first-deep-link"
)

/// The path taken by a macro-first host that has no ``RouterLinkHandling``.
///
/// A host is a candidate whenever its route type resolves the URL; whether the
/// link can be applied is decided by the Store when the request executes.
///
/// - The exact-state plan is derived from the state at execution. Deriving it
///   at URL arrival would silently revert every commit that lands in the
///   main-actor turns before the request runs.
/// - A host that cannot apply the link when it arrives (for example while a
///   sheet covers its selected stack) yields to any host that can, exactly as
///   it did when it stepped aside in 7.0. When no host can, it still submits
///   the request, which is decided when it executes: it applies if a commit
///   made it applicable meanwhile, and otherwise ends as an ordinary rejected
///   request instead of disappearing: ``RouterEvent`` observers see it, and
///   this path logs its kind.
/// - A link that reaches a host whose scope was replaced, before the host
///   renders again (for example right after a restore), is treated the same
///   way: the host cannot apply it, and its request ends as an expired-scope
///   rejection unless another host answers.
/// - `fallbackPlan` must not capture the Store. The request keeps it for as
///   long as it is queued or deferred, and the Store keeps the request.
@MainActor
func submitDefaultRouterPlanLink<R: Route>(
    _ routeType: R.Type,
    url: URL,
    scope: RouterScope<R>,
    context: RouterDeepLinkContext,
    source: RouterDeepLinkSource,
    fallbackPlan: @escaping @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R>
) {
    guard let resolver = routeType as? any DeepLinkRoute.Type,
          let route = resolver.resolveDeepLink(url) as? R else { return }
    // Decides only which host answers. Whether the link applies is decided
    // again, from the state at execution, by the request itself. An expired
    // scope has no state to decide from.
    let isApplicable = scope.state.map { (try? fallbackPlan(route, $0)) != nil } ?? false
    let authorization = RouterRequestAuthorization<R>(matchedRoutes: [route], configuration: nil)
    let executionPrecondition = scope.captureLinkAuthorizationPrecondition(request: authorization)
    let path = scope.path
    let preparation: RouterRequestPreparationBuilder<R> = { state in
        do {
            return .action(.apply(try fallbackPlan(route, state)))
        } catch {
            return .rejected(routerPreparationRejection(for: error, at: path))
        }
    }
    context.arbiter.submit(url: url, source: source, depth: context.depth, isApplicable: isApplicable) {
        Task { @MainActor in
            let outcome = await scope.performRoot(
                preparedBy: preparation, context: .init(source: .deepLink),
                executionPrecondition: executionPrecondition, authorization: authorization
            )
            guard case .rejected(_, _, _, let reason) = outcome else { return }
            // The URL and route payload are never logged.
            let description = String(describing: reason)
            let kind = String(description.prefix { $0 != "(" })
            routerDefaultLinkLogger.warning(
                "A macro-first host rejected an incoming deep link: \(kind, privacy: .public)"
            )
        }
    }
}
