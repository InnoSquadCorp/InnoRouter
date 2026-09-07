import Foundation
import SwiftUI

import InnoRouterCore
import InnoRouterDeepLink
import InnoRouterSwiftUI

/// Payload-free projection of a deep-link explanation for developer tools.
public struct RouterInspectorDeepLinkAnalysis: Sendable, Equatable {
    public let decision: String
    public let attempts: [DeepLinkRouteAttempt]
    public let catalog: DeepLinkRouteCatalog
    public let proposedState: RouterInspectorStateTree?
    public let diff: RouterInspectorStateDiff?

    public init(
        decision: String,
        attempts: [DeepLinkRouteAttempt],
        catalog: DeepLinkRouteCatalog,
        proposedState: RouterInspectorStateTree? = nil,
        diff: RouterInspectorStateDiff? = nil
    ) {
        self.decision = decision
        self.attempts = attempts
        self.catalog = catalog
        self.proposedState = proposedState
        self.diff = diff
    }
}

public enum RouterInspectorDeepLinkAnalyzer {
    /// Payload-free text suitable for the default copy/share action.
    public static func shareSummary(
        _ analysis: RouterInspectorDeepLinkAnalysis
    ) -> String {
        let attempts = analysis.attempts.map {
            "\($0.pattern):\($0.outcome.rawValue)"
        }.joined(separator: "\n")
        return "\(analysis.decision)\n\(attempts)"
    }

    public static func analyze<R: DeepLinkRoute>(
        _ url: URL,
        as routeType: R.Type,
        inputLimits: DeepLinkInputLimits = .default
    ) -> RouterInspectorDeepLinkAnalysis {
        let explanation = routeType.explainDeepLink(url, inputLimits: inputLimits)
        return RouterInspectorDeepLinkAnalysis(
            decision: decisionDescription(explanation.decision),
            attempts: explanation.attempts,
            catalog: routeType.deepLinkCatalog
        )
    }

    /// Uses the pure reducer to show the structural target and diff. App-owned
    /// resolvers that did not opt into pure explanation remain unevaluated.
    public static func preview<R: DeepLinkRoute>(
        _ url: URL,
        as routeType: R.Type,
        from state: RouterState<R>,
        action: (R) -> RouterAction<R> = RouterAction.push
    ) -> RouterInspectorDeepLinkAnalysis {
        guard routeType.supportsPureDeepLinkExplanation,
              routeType.deepLinkCatalog.supportsPureResolution(of: url) else {
            return analyze(url, as: routeType)
        }
        let route = routeType.resolveDeepLink(url)
        let explanation = routeType.deepLinkCatalog.explain(
            url,
            shouldResolve: true,
            resolve: { _ in route },
            resolvedCaseName: routeType.deepLinkCatalogCaseName
        )
        let analysis = RouterInspectorDeepLinkAnalysis(
            decision: decisionDescription(explanation.decision),
            attempts: explanation.attempts,
            catalog: routeType.deepLinkCatalog
        )
        guard let route,
              let target = try? RouterReducer.reduce(action(route), from: state) else {
            return analysis
        }
        return .init(
            decision: analysis.decision,
            attempts: analysis.attempts,
            catalog: analysis.catalog,
            proposedState: RouterInspectorProjection.tree(from: target),
            diff: RouterInspectorProjection.diff(from: state, to: target)
        )
    }

    /// Explicitly resolves and submits one URL through the canonical store.
    /// Returning `nil` means the URL did not resolve and no request was sent.
    @MainActor
    public static func execute<R: DeepLinkRoute>(
        _ url: URL,
        on store: RouterStore<R>,
        action: (R) -> RouterAction<R> = RouterAction.push
    ) async -> RouterOutcome<R>? {
        guard let route = R.resolveDeepLink(url) else { return nil }
        return await store.perform(
            action(route),
            context: .init(source: .inspector)
        )
    }

    private static func decisionDescription(
        _ decision: DeepLinkResolutionExplanation.Decision
    ) -> String {
        switch decision {
        case .accepted(let routeCase, let pattern):
            return "accepted \(routeCase) via \(pattern)"
        case .rejected(let failure):
            return switch failure {
            case .credentialsNotAllowed: "rejected: credentials-not-allowed"
            case .portNotAllowed: "rejected: port-not-allowed"
            case .schemeNotAllowed: "rejected: scheme-not-allowed"
            case .hostNotAllowed: "rejected: host-not-allowed"
            case .inputLimitExceeded: "rejected: input-limit-exceeded"
            case .noMatchingPattern: "rejected: no-matching-pattern"
            case .parameterConversionFailed: "rejected: parameter-conversion-failed"
            case .customResolverNotEvaluated: "not-evaluated: custom-resolver"
            }
        }
    }
}

/// Opt-in Inspector surface for trying URLs against a macro route catalog.
@MainActor
public struct RouterInspectorDeepLinkView<R: DeepLinkRoute>: View {
    private let routeType: R.Type
    private let store: RouterStore<R>?
    private let action: @MainActor (R) -> RouterAction<R>
    @State private var input: String
    @State private var catalogFilter = ""
    @State private var executionTask: Task<Void, Never>?
    @State private var executionStatus: RouterInspectorExecutionStatus?

    public init(_ routeType: R.Type, initialURL: String = "") {
        self.routeType = routeType
        self.store = nil
        self.action = RouterAction.push
        self._input = State(initialValue: initialURL)
    }

    /// Adds an explicit execution button. Preview remains reducer-only, while
    /// execution resolves the URL and enters the store's normal policy queue.
    public init(
        store: RouterStore<R>,
        initialURL: String = "",
        action: @escaping @MainActor (R) -> RouterAction<R> = RouterAction.push
    ) {
        self.routeType = R.self
        self.store = store
        self.action = action
        self._input = State(initialValue: initialURL)
    }

    public var body: some View {
        Form {
            TextField(routerInspectorLocalized("URL"), text: $input)
            if let analysis {
                Section(routerInspectorLocalized("Decision")) {
                    Text(verbatim: analysis.decision)
                        .font(.body.monospaced())
                }
                Section(routerInspectorLocalized("Ordered attempts")) {
                    ForEach(Array(analysis.attempts.enumerated()), id: \.offset) { _, attempt in
                        LabeledContent(attempt.pattern) {
                            Text(verbatim: attempt.outcome.rawValue)
                        }
                    }
                }
                if let diff = analysis.diff {
                    Section(routerInspectorLocalized("Target difference")) {
                        if diff.changes.isEmpty {
                            Text(verbatim: routerInspectorLocalized("No structural change"))
                        } else {
                            ForEach(diff.changes) { change in
                                LabeledContent(change.path) {
                                    Text(verbatim: "\(change.field): \(change.before) → \(change.after)")
                                }
                            }
                        }
                    }
                }
            }
            Section(routerInspectorLocalized("Generated catalog")) {
                ForEach(filteredCatalogEntries) { entry in
                    VStack(alignment: .leading) {
                        Text(verbatim: entry.routeCase)
                        Text(verbatim: entry.pattern)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: routerInspectorLocalized("Deep-link Inspector")))
        .searchable(
            text: $catalogFilter,
            prompt: Text(verbatim: routerInspectorLocalized("Filter catalog"))
        )
        .toolbar {
#if os(iOS) || os(macOS) || os(visionOS)
            if !input.isEmpty {
                ShareLink(item: safeAnalysisSummary) {
                    Label(
                        routerInspectorLocalized("Share analysis"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
#endif
            if store != nil {
                Button {
                    execute()
                } label: {
                    Label(routerInspectorLocalized("Execute"), systemImage: "play.fill")
                }
                .disabled(input.isEmpty || executionTask != nil)
                if executionTask != nil {
                    Button(role: .cancel) {
                        executionTask?.cancel()
                    } label: {
                        Label(routerInspectorLocalized("Cancel"), systemImage: "xmark")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let executionStatus {
                Text(verbatim: routerInspectorLocalized(executionStatus.rawValue))
                    .font(.caption.monospaced())
                    .padding(8)
            }
        }
        .onDisappear {
            executionTask?.cancel()
            executionTask = nil
        }
    }

    private var analysis: RouterInspectorDeepLinkAnalysis? {
        guard let url = URL(string: input), !input.isEmpty else { return nil }
        if let store {
            return RouterInspectorDeepLinkAnalyzer.preview(
                url,
                as: routeType,
                from: store.state,
                action: action
            )
        }
        return RouterInspectorDeepLinkAnalyzer.analyze(url, as: routeType)
    }

    private var filteredCatalogEntries: [DeepLinkRouteCatalogEntry] {
        guard !catalogFilter.isEmpty else { return routeType.deepLinkCatalog.entries }
        let needle = catalogFilter.localizedLowercase
        return routeType.deepLinkCatalog.entries.filter { entry in
            entry.routeCase.localizedLowercase.contains(needle)
                || entry.pattern.localizedLowercase.contains(needle)
                || entry.declarationNamespace.localizedLowercase.contains(needle)
                || entry.featurePath.joined(separator: ".").localizedLowercase.contains(needle)
                || entry.parameters.contains { parameter in
                    parameter.name.localizedLowercase.contains(needle)
                        || parameter.typeName.localizedLowercase.contains(needle)
                }
        }
    }

    private var safeAnalysisSummary: String {
        guard let analysis else { return routerInspectorLocalized("Invalid URL") }
        return RouterInspectorDeepLinkAnalyzer.shareSummary(analysis)
    }

    private func execute() {
        guard let store, let url = URL(string: input) else { return }
        executionTask = Task { @MainActor in
            defer { executionTask = nil }
            guard !Task.isCancelled else {
                executionStatus = .cancelled
                return
            }
            guard let outcome = await RouterInspectorDeepLinkAnalyzer.execute(
                url,
                on: store,
                action: action
            ) else {
                executionStatus = Task.isCancelled ? .cancelled : .unresolved
                return
            }
            guard !Task.isCancelled else {
                executionStatus = .cancelled
                return
            }
            executionStatus = switch outcome {
            case .applied: .applied
            case .unchanged: .unchanged
            case .deferred: .deferred
            case .rejected(_, _, _, .cancelled): .cancelled
            case .rejected: .rejected
            }
        }
    }
}
