import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum RuntimeDependencyRoute: Route {
    case detail
}

@Suite("Router deterministic runtime dependencies")
@MainActor
struct RouterRuntimeDependencyTests {
    @Test("Policy timeout advances without waiting for wall-clock time", arguments: 0..<100)
    func policyTimeout(_: Int) async {
        let sleeper = ManualRuntimeSleeper()
        var registrations = sleeper.registrations.makeAsyncIterator()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        var configuration = RouterStoreConfiguration<RuntimeDependencyRoute>(
            policies: [
                RouterPolicy(name: "remote") { _ in
                    for await _ in gate {}
                    return .allow
                }
            ],
            policyTimeout: .seconds(30)
        )
        configuration.runtimeDependencies = manualRuntimeDependencies(sleeper: sleeper)
        let store = RouterStore<RuntimeDependencyRoute>(configuration: configuration)

        let request = Task { @MainActor in
            await store.perform(.push(.detail))
        }
        #expect(await registrations.next() == .seconds(30))
        await sleeper.resumeAll()

        guard case .rejected(let id, _, _, let reason) = await request.value else {
            Issue.record("Expected deterministic timeout")
            gateContinuation.finish()
            return
        }
        #expect(reason == .policyTimedOut(name: "remote"))
        #expect(id == Self.fixedTransitionID)
        #expect(store.revision == 0)
        gateContinuation.finish()
    }

    @Test("Deferral timestamps and expiration use the same injected clock", arguments: 0..<100)
    func deferralExpiration(_: Int) async {
        let sleeper = ManualRuntimeSleeper()
        var registrations = sleeper.registrations.makeAsyncIterator()
        let deferralID = RouterDeferralID(
            rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        )
        var configuration = RouterStoreConfiguration<RuntimeDependencyRoute>(
            policies: [
                RouterPolicy(name: "approval") { _ in .deferRequest(deferralID) }
            ],
            deferrals: .init(timeToLive: .seconds(60))
        )
        configuration.runtimeDependencies = manualRuntimeDependencies(sleeper: sleeper)
        let store = RouterStore<RuntimeDependencyRoute>(configuration: configuration)
        let expiryEvents = store.events

        guard case .deferred(_, _, _, let deferred) = await store.perform(.push(.detail)) else {
            Issue.record("Expected deferred request")
            return
        }
        #expect(deferred.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(deferred.expiresAt == Date(timeIntervalSince1970: 1_060))
        #expect(deferred.transitionID == Self.fixedTransitionID)
        #expect(await registrations.next() == .seconds(60))

        let expiredEvent = Task { @MainActor in
            var events = expiryEvents.makeAsyncIterator()
            while let event = await events.next() {
                guard case .rejected(_, _, _, let reason, _) = event else { continue }
                if reason == .deferralExpired(deferralID) { return true }
            }
            return false
        }
        await sleeper.resumeAll()

        #expect(await expiredEvent.value)
        #expect(store.deferredTransitions.isEmpty)
    }

    private static let fixedTransitionID = RouterTransitionID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    )
}
