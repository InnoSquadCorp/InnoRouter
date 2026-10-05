import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Native scene-host path admission", .timeLimit(.minutes(1)))
@MainActor
struct RouterSceneHostAdmissionTests {
    private enum R: Route { case home }

    @Test("Oversized absent IDs reject before missing-scene repair can be selected")
    func oversizedAbsentIdentity() throws {
        let store = try RouterStore<R>(configuration: .init(
            resourceBudget: .init(snapshot: .init(maximumPayloadBytes: 4))
        ))
        do {
            _ = try store.admittedSceneHostScope(at: .immersiveSpace("ééx"))
            Issue.record("Oversized absence must not be reported as an ordinary missing scene")
        } catch {
            #expect(error.code == .resourceLimit)
            #expect(error.resourceLimit?.maximum == 4)
        }
        #expect(store.scopes.isEmpty)
        #expect(store.scopeLifetimeObservations.isEmpty)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(try store.admittedSceneHostScope(at: .immersiveSpace("éé")) == nil)
    }

    @Test("Malformed scene paths are explicit errors even when no scene exists")
    func malformedPaths() throws {
        let store = RouterStore<R>()
        for path in [RouterScopePath.root, .immersiveSpace(""), .window(UUID()).appending("child")] {
            do {
                _ = try store.admittedSceneHostScope(at: path)
                Issue.record("Malformed path must not authorize absence repair")
            } catch { #expect(error.code == .invalidScope) }
        }
        #expect(store.scopes.isEmpty)
        #expect(store.revision == 0)
    }

    @Test("Valid missing scene roots remain eligible for native lifecycle repair")
    func validMissingControl() throws {
        let store = RouterStore<R>()
        #expect(try store.admittedSceneHostScope(at: .window(UUID())) == nil)
        #expect(try store.admittedSceneHostScope(at: .immersiveSpace("absent")) == nil)
        #expect(store.scopes.isEmpty)
        #expect(store.revision == 0)
    }

    @Test("Live scene roots return their exact same-Store canonical projection")
    func liveSceneControl() throws {
        let id = UUID()
        let state = try RouterState<R>(
            windows: [.init(id: id, route: .home, node: .stack(path: [.home]))],
            immersiveSpace: .init(id: "live", route: .home)
        )
        let store = try RouterStore(initialState: state)
        let window = try #require(try store.admittedSceneHostScope(at: .window(id)))
        let immersive = try #require(try store.admittedSceneHostScope(at: .immersiveSpace("live")))
        #expect(window === store.scope(at: .window(id)))
        #expect(immersive === store.scope(at: .immersiveSpace("live")))
        #expect(window.store === store)
        #expect(window.node == .stack(path: [.home]))
        #expect(store.state == state)
        #expect(store.revision == 0)
    }
}
