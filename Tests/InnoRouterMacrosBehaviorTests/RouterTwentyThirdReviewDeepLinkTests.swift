#if canImport(InnoRouterMacrosPlugin)
import Foundation
import SwiftUI
import Synchronization
import Testing

import InnoRouterDeepLink
import InnoRouterMacros

private enum TwentyThirdConversionContext {
    @TaskLocal static var didParse: (@Sendable () -> Void)?
}

private struct TwentyThirdReferenceID: Hashable, Sendable, DeepLinkParameterValue {
    let value: String

    static func parseDeepLinkParameter(_ value: String) -> Self? {
        TwentyThirdConversionContext.didParse?()
        guard TwentyThirdNestedRoute.resolveDeepLink(URL(string: "r23://app/anchor")!) != nil else {
            return nil
        }
        return Self(value: value)
    }
}

@Router(deepLinkSchemes: ["r23"], deepLinkHosts: ["app"])
private indirect enum TwentyThirdOuterRoute {
    @DeepLink("/anchor")
    case anchor

    @FeatureRoute
    case nested(TwentyThirdNestedRoute)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["r23"], deepLinkHosts: ["app"])
private indirect enum TwentyThirdNestedRoute {
    @DeepLink("/reference/:id")
    case reference(id: TwentyThirdReferenceID)

    @FeatureRoute
    case outer(TwentyThirdOuterRoute)

    var destination: some View { EmptyView() }
}

@Suite("Twenty-third review nested traversal isolation")
struct RouterTwentyThirdReviewDeepLinkTests {
    @Test("A parameter conversion owns its independent nested lookup")
    func independentLookupInsideParameterConversion() throws {
        let url = try #require(URL(string: "r23://app/reference/42"))
        let anchor = try #require(URL(string: "r23://app/anchor"))
        #expect(TwentyThirdNestedRoute.resolveDeepLink(anchor) == .outer(.anchor))
        #expect(TwentyThirdNestedRoute.resolveDeepLink(url) == .reference(id: .init(value: "42")))
        #expect(TwentyThirdOuterRoute.resolveDeepLink(url) == .nested(.reference(id: .init(value: "42"))))
    }

    @Test("A different nested root cannot pass on the previous child's permit")
    func aDifferentNestedRootClearsAdmission() throws {
        let url = try #require(URL(string: "r23://app/reference/42"))
        let anchor = try #require(URL(string: "r23://app/anchor"))
        TwentyThirdConversionContext.$didParse.withValue({
            let value = DeepLinkFeatureRuntime.resolve(TwentyThirdOuterRoute.self, url: anchor) {
                // A direct B root must not inherit the outer A -> B permit.
                TwentyThirdNestedRoute.resolveDeepLink(anchor) == .outer(.anchor) ? .anchor : nil
            }
            #expect(value == .anchor)
        }) {
            #expect(TwentyThirdOuterRoute.resolveDeepLink(url) != nil)
        }
    }

    @Test("Tasks created by conversions start independent generated roots")
    func inheritedTaskLocalDoesNotReuseAdmission() async throws {
        let url = try #require(URL(string: "r23://app/reference/42"))
        let anchor = try #require(URL(string: "r23://app/anchor"))
        let tasks = Mutex<[Task<Bool, Never>]>([])
        // A two-entry parent budget makes leakage observable even after the
        // originating call has unwound. The task owns its normal-size budget.
        TwentyThirdConversionContext.$didParse.withValue({
            let task = Task {
                DeepLinkTraversalTestSupport.withLimits(.production) {
                    TwentyThirdNestedRoute.resolveDeepLink(anchor) == .outer(.anchor)
                }
            }
            tasks.withLock { $0.append(task) }
        }) {
            DeepLinkTraversalTestSupport.withLimits(.init(maximumDepth: 64, maximumEntryAttempts: 2)) {
                _ = TwentyThirdOuterRoute.resolveDeepLink(url)
            }
        }
        let spawned = tasks.withLock { $0 }
        defer { spawned.forEach { $0.cancel() } }
        #expect(spawned.count == 1)
        for task in spawned {
            #expect(await task.value)
        }
    }
}
#endif
