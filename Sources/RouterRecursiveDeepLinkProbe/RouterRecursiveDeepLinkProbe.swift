import Foundation
import SwiftUI

import InnoRouter

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
indirect enum RecursiveProbeRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(Self)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
indirect enum MutualProbeRouteA {
    @DeepLink("/a/:id")
    case leaf(id: String)

    @FeatureRoute
    case toB(MutualProbeRouteB)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
indirect enum MutualProbeRouteB {
    @DeepLink("/b/:id")
    case leaf(id: String)

    @FeatureRoute
    case toA(MutualProbeRouteA)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
enum PlainProbeRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
enum FeatureChildProbeRoute {
    @DeepLink("/child/:id")
    case leaf(id: String)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
enum FeatureParentProbeRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(FeatureChildProbeRoute)

    var destination: some View { EmptyView() }
}

/// Every edge changes the concrete specialization, so identity-only cycle
/// checks cannot terminate this graph.
@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"], inspectorCatalog: true)
indirect enum ExpandingProbeRoute<Value: Hashable & Sendable> {
    @DeepLink("/growing/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(ExpandingProbeRoute<[Value]>)

    var destination: some View { EmptyView() }
}

@main
enum RouterRecursiveDeepLinkProbe {
    static func main() throws {
        let url = URL(string: "probe://app/leaf/42")!
        let mutualURL = URL(string: "probe://app/a/7")!
        let childURL = URL(string: "probe://app/child/42")!
        let growingURL = URL(string: "probe://app/growing/42")!
        let origin = DeepLinkOrigin(scheme: "probe", host: "app")!
        let selfCatalog = RecursiveProbeRoute.deepLinkCatalog.entries.map(\.routeCase)
        let selfLocalResolved = RecursiveProbeRoute.resolveDeepLink(url) == .leaf(id: "42")
        let selfURLRoundTrips = RecursiveProbeRoute.leaf(id: "42").deepLinkURL(origin: origin) == url

        try require(
            selfCatalog == ["leaf"],
            "self catalog must retain only the local leaf"
        )
        try require(!RecursiveProbeRoute.supportsPureDeepLinkExplanation, "cycle must be impure")
        try require(
            selfLocalResolved,
            "self-recursive root must still resolve its local leaf"
        )
        try require(
            RecursiveProbeRoute.deepLinkCatalogCaseName(for: .leaf(id: "42")) == "leaf",
            "local case name must survive"
        )
        try require(
            selfURLRoundTrips,
            "local outbound URL must round-trip"
        )
        try require(
            RecursiveProbeRoute.child(.leaf(id: "42")).deepLinkURL(origin: origin) == nil,
            "cyclic outbound edge must fail closed"
        )

        try require(
            PlainProbeRoute.deepLinkCatalog.entries.map(\.routeCase) == ["leaf"],
            "plain control catalog must contain its leaf"
        )
        try require(PlainProbeRoute.supportsPureDeepLinkExplanation, "plain control must be pure")
        try require(PlainProbeRoute.resolveDeepLink(url) == .leaf(id: "42"), "plain resolve")
        try require(PlainProbeRoute.leaf(id: "42").deepLinkURL(origin: origin) == url, "plain URL")

        try require(
            FeatureParentProbeRoute.deepLinkCatalog.entries.map(\.routeCase)
                == ["leaf", "child.leaf"],
            "non-recursive feature catalog must retain both paths"
        )
        try require(FeatureParentProbeRoute.supportsPureDeepLinkExplanation, "feature control")
        try require(FeatureParentProbeRoute.resolveDeepLink(url) == .leaf(id: "42"), "parent local")
        try require(
            FeatureParentProbeRoute.resolveDeepLink(childURL) == .child(.leaf(id: "42")),
            "parent child resolve"
        )
        try require(
            FeatureParentProbeRoute.child(.leaf(id: "42")).deepLinkURL(origin: origin)
                == childURL,
            "parent child URL"
        )

        let mutualCatalog = MutualProbeRouteA.deepLinkCatalog.entries.map(\.routeCase).sorted()
        try require(
            mutualCatalog == ["leaf", "toB.leaf"],
            "mutual cycle must keep both non-cyclic leaves"
        )
        try require(MutualProbeRouteA.resolveDeepLink(mutualURL) == .leaf(id: "7"), "mutual local")

        let growingCatalog = ExpandingProbeRoute<Int>.deepLinkCatalog
        let growingResolved = ExpandingProbeRoute<Int>.resolveDeepLink(growingURL) != nil
        let growingDecision = switch ExpandingProbeRoute<Int>.explainDeepLink(growingURL).decision {
        case .rejected(.traversalLimitExceeded): "traversal-limit-exceeded"
        default: "unexpected"
        }
        try require(!growingCatalog.isComplete, "growing catalog must report its limit")
        try require(growingCatalog.entries.isEmpty, "growing catalog must not expose a prefix")
        try require(
            !ExpandingProbeRoute<Int>.supportsPureDeepLinkExplanation,
            "growing purity must fail closed"
        )
        try require(
            !growingResolved,
            "growing resolve must fail closed"
        )
        try require(
            growingDecision == "traversal-limit-exceeded",
            "growing explain must identify the traversal limit"
        )

        let report = ProbeReport(
            selfCatalog: selfCatalog,
            selfLocalResolved: selfLocalResolved,
            selfURLRoundTrips: selfURLRoundTrips,
            mutualCatalog: mutualCatalog,
            growingCatalogComplete: growingCatalog.isComplete,
            growingCatalogEntries: growingCatalog.entries.map(\.routeCase),
            growingResolved: growingResolved,
            growingDecision: growingDecision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(report)
        print("[recursive-deep-link-probe] \(String(decoding: encoded, as: UTF8.self))")
    }

    private struct ProbeReport: Encodable {
        let schemaVersion = 1
        let selfCatalog: [String]
        let selfLocalResolved: Bool
        let selfURLRoundTrips: Bool
        let mutualCatalog: [String]
        let growingCatalogComplete: Bool
        let growingCatalogEntries: [String]
        let growingResolved: Bool
        let growingDecision: String
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw ProbeFailure(description: message) }
    }
}
