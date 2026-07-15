// MARK: - FlowStoreStateProjectionTests.swift
// InnoRouterTests - public FlowStore state projections
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum ReadingRoute: Route {
    case home
    case detail(Int)
    case settings
}

@Suite("FlowStore state projections")
@MainActor
struct FlowStoreStateProjectionTests {

    @Test("empty FlowStore exposes empty navigationPath and nil modal")
    func empty_projection() {
        let flow = FlowStore<ReadingRoute>()

        #expect(flow.path.isEmpty)
        #expect(flow.navigationPath.isEmpty)
        #expect(flow.currentModalRoute == nil)
        #expect(flow.currentModalPresentation == nil)
        #expect(!flow.hasModalTail)
    }

    @Test("push-only path projects to navigationPath without a modal route")
    func pushOnly_projection() {
        let flow = FlowStore<ReadingRoute>()
        flow.apply(FlowPlan(steps: [.push(.home), .push(.detail(1))]))

        #expect(flow.navigationPath == [.home, .detail(1)])
        #expect(flow.currentModalRoute == nil)
        #expect(!flow.hasModalTail)
    }

    @Test("trailing sheet step projects to currentModalRoute")
    func sheetTail_projection() {
        let flow = FlowStore<ReadingRoute>()
        flow.apply(FlowPlan(steps: [.push(.home), .sheet(.settings)]))

        #expect(flow.navigationPath == [.home])
        #expect(flow.currentModalRoute == .settings)
        #expect(flow.hasModalTail)
    }

    @Test("currentModalPresentation keeps the active modal identity stable")
    func modalPresentationIdentity_isStableAcrossReads() throws {
        let flow = FlowStore<ReadingRoute>()
        flow.apply(FlowPlan(steps: [.push(.home), .sheet(.settings)]))

        let first = try #require(flow.currentModalPresentation)
        let second = try #require(flow.currentModalPresentation)

        #expect(first.route == .settings)
        #expect(first.style == .sheet)
        #expect(first.id == second.id)
    }

    @Test("trailing cover step also projects to currentModalRoute")
    func coverTail_projection() {
        let flow = FlowStore<ReadingRoute>()
        flow.apply(FlowPlan(steps: [.push(.home), .cover(.detail(2))]))

        #expect(flow.navigationPath == [.home])
        #expect(flow.currentModalRoute == .detail(2))
        #expect(flow.hasModalTail)
    }
}
