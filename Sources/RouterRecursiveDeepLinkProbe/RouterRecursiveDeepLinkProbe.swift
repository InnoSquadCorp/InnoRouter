import Foundation
import SwiftUI

import InnoRouter

/// A route that reaches itself through a feature case.
///
/// Every generated deep-link entry point walks the feature graph, so this
/// declaration re-enters its own contract. The probe exists to prove that each
/// entry terminates instead of recursing until the stack overflows.
@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"])
indirect enum RecursiveProbeRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(Self)

    var destination: some View { EmptyView() }
}

/// Two routes that reach each other, which no single-type check would catch.
@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"])
indirect enum MutualProbeRouteA {
    @DeepLink("/a/:id")
    case leaf(id: String)

    @FeatureRoute
    case toB(MutualProbeRouteB)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"])
indirect enum MutualProbeRouteB {
    @DeepLink("/b/:id")
    case leaf(id: String)

    @FeatureRoute
    case toA(MutualProbeRouteA)

    var destination: some View { EmptyView() }
}

/// The non-recursive control. Any difference from this baseline is caused by
/// the recursion guard, not by the deep-link contract itself.
@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"])
enum PlainProbeRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    var destination: some View { EmptyView() }
}

/// A non-recursive route that still owns a feature child, to separate "has a
/// feature case" from "reaches itself".
@Router(deepLinkSchemes: ["probe"], deepLinkHosts: ["app"])
enum FeatureParentProbeRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(PlainProbeRoute)

    var destination: some View { EmptyView() }
}

@main
enum RouterRecursiveDeepLinkProbe {
    static func main() {
        let url = URL(string: "probe://app/leaf/42")!
        let mutualURL = URL(string: "probe://app/a/7")!

        report("self.catalog", RecursiveProbeRoute.deepLinkCatalog.entries.count)
        report("self.pure", RecursiveProbeRoute.supportsPureDeepLinkExplanation)
        report("self.resolve", RecursiveProbeRoute.resolveDeepLink(url) != nil)
        report("self.explain", RecursiveProbeRoute.explainDeepLink(url).decision)
        report(
            "self.caseName",
            RecursiveProbeRoute.deepLinkCatalogCaseName(for: .leaf(id: "42")) ?? "nil"
        )
        report(
            "self.url",
            RecursiveProbeRoute.leaf(id: "42")
                .deepLinkURL(origin: DeepLinkOrigin(scheme: "probe", host: "app")!)?
                .absoluteString ?? "nil"
        )

        report("plain.catalog", PlainProbeRoute.deepLinkCatalog.entries.count)
        report("plain.pure", PlainProbeRoute.supportsPureDeepLinkExplanation)
        report("plain.resolve", PlainProbeRoute.resolveDeepLink(url) != nil)
        report(
            "plain.url",
            PlainProbeRoute.leaf(id: "42")
                .deepLinkURL(origin: DeepLinkOrigin(scheme: "probe", host: "app")!)?
                .absoluteString ?? "nil"
        )

        report("featureParent.catalog", FeatureParentProbeRoute.deepLinkCatalog.entries.count)
        report("featureParent.pure", FeatureParentProbeRoute.supportsPureDeepLinkExplanation)
        report("featureParent.resolve", FeatureParentProbeRoute.resolveDeepLink(url) != nil)
        report(
            "featureParent.url",
            FeatureParentProbeRoute.leaf(id: "42")
                .deepLinkURL(origin: DeepLinkOrigin(scheme: "probe", host: "app")!)?
                .absoluteString ?? "nil"
        )

        report("mutual.catalog", MutualProbeRouteA.deepLinkCatalog.entries.count)
        report("mutual.pure", MutualProbeRouteA.supportsPureDeepLinkExplanation)
        report("mutual.resolve", MutualProbeRouteA.resolveDeepLink(mutualURL) != nil)
        report("mutual.explain", MutualProbeRouteA.explainDeepLink(mutualURL).decision)

        print("[recursive-deep-link-probe] every entry point terminated")
    }

    private static func report(_ label: String, _ value: some Any) {
        print("[recursive-deep-link-probe] \(label) = \(value)")
    }
}
