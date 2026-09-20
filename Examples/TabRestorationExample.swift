import Foundation
import SwiftUI

import InnoRouter

// Requires the unreleased 6.1 tab-topology APIs. See Examples/README.md.
@Router
enum RestorableTabRoute: Codable {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gearshape")
    case settings

    case detail(id: String)

    var destination: some View {
        switch self {
        case .home, .settings:
            RestorableTabActions()
        case .detail(let id):
            Text("Detail \(id)")
                .navigationTitle("Saved detail")
        }
    }
}

private struct RestorableTabActions: View {
    @EnvironmentRouter(RestorableTabRoute.self) private var router

    var body: some View {
        Button("Open detail") {
            router.go(.detail(id: "42"))
        }
    }
}

// One session per scene, retained by @State below. The host and driver share
// this store and catalog; the driver never owns separate navigation state.
@MainActor
final class TabRestorationExampleSession {
    let store: RouterStore<RestorableTabRoute>
    let catalog: RouterTabCatalog<RestorableTabRoute>
    let driver: RouterRestorationDriver<RestorableTabRoute>

    init(snapshotURL: URL) throws {
        let catalog = try RouterTabCatalog(RestorableTabRoute.routerTabs)
        let store = RestorableTabRoute.makeRouterStore()
        let limits = try RouterSnapshotLimits(
            maximumEncodedByteCount: 2 * 1_024 * 1_024,
            maximumPayloadByteCount: 1 * 1_024 * 1_024
        )
        self.catalog = catalog
        self.store = store
        self.driver = RouterRestorationDriver(
            store: store,
            codec: try RouterSnapshotCodec(currentVersion: 1, limits: limits),
            storage: try RouterFileSnapshotStorage(
                fileURL: snapshotURL,
                maximumByteCount: limits.maximumEncodedByteCount
            ),
            recovery: .fail,
            tabTopology: RouterTabRestorationTopology(catalog: catalog)
        )
    }

    // Demo setup only: explicitly overwrites the given file. Run before mounting
    // the example, with a dedicated demo URL and no other driver using that URL.
    // The old catalog contained home/legacy; the current one is home/settings.
    static func writePreviousVersionSnapshot(to snapshotURL: URL) async throws {
        let state = try RouterState<RestorableTabRoute>(root: .container(.init(
            style: .tabs, selection: "legacy", branches: [
                .init(id: "home", node: .stack(path: [.detail(id: "saved-home")])),
                .init(id: "legacy", node: .stack(path: [.detail(id: "saved-legacy")])),
            ]
        )))
        let limits = try RouterSnapshotLimits(
            maximumEncodedByteCount: 2 * 1_024 * 1_024,
            maximumPayloadByteCount: 1 * 1_024 * 1_024
        )
        let writer = RouterRestorationDriver(
            store: RouterStore(initialState: state),
            codec: try RouterSnapshotCodec(currentVersion: 1, limits: limits),
            storage: try RouterFileSnapshotStorage(
                fileURL: snapshotURL,
                maximumByteCount: limits.maximumEncodedByteCount
            )
        )
        defer { writer.stop() }
        // The driver's storage executor performs file I/O off the main actor.
        try await writer.save()
    }
}

// Copy this file into an app and place this view in its WindowGroup. Choose a
// stable Application Support URL; use a separate file for each account/scene.
struct TabRestorationExampleView: View {
    let snapshotURL: URL
    @State private var session: TabRestorationExampleSession?
    @State private var setupError: String?

    var body: some View {
        Group {
            if let session {
                TabRestorationExampleContent(session: session)
            } else if let setupError {
                Text("Unable to configure restoration: \(setupError)")
            } else {
                ProgressView("Preparing navigation")
            }
        }
        .task {
            guard session == nil else { return }
            do {
                session = try TabRestorationExampleSession(snapshotURL: snapshotURL)
            } catch {
                setupError = String(describing: error)
            }
        }
    }
}

// Optional tutorial launcher. Ordinary apps use TabRestorationExampleView
// directly; only this demo explicitly offers to replace a saved snapshot.
struct TabRestorationUpgradeDemoView: View {
    let snapshotURL: URL
    @State private var preparing = false
    @State private var ready = false
    @State private var failure: String?

    var body: some View {
        Group {
            if ready {
                TabRestorationExampleView(snapshotURL: snapshotURL)
            } else {
                VStack {
                    Text("Create an old home/legacy snapshot, then restore into home/settings.")
                    Text("Creating the demo replaces the saved file at the supplied URL.")
                    Button("Create previous-version demo") { preparing = true }
                    Button("Open saved session") { ready = true }
                    if let failure { Text("Demo setup failed: \(failure)") }
                }
                .disabled(preparing)
            }
        }
        .task(id: preparing) {
            guard preparing else { return }
            defer { preparing = false }
            do {
                try await TabRestorationExampleSession.writePreviousVersionSnapshot(to: snapshotURL)
                try Task.checkCancellation()
                ready = true
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

private struct TabRestorationExampleContent: View {
    let session: TabRestorationExampleSession
    @State private var saveRequested = false
    @State private var saved = false

    var body: some View {
        // This initializer permits preserved orphan branches, but still checks
        // that current scopes are stacks and selection belongs to the catalog.
        let host = Result {
            try RouterTabHost(
                store: session.store,
                catalog: session.catalog,
                allowingOrphanedBranches: true
            )
        }
        switch host {
        case .success(let host):
            VStack {
                host
                TabRestorationResultView(driver: session.driver)
                Button("Save now") {
                    saved = false
                    saveRequested = true
                }
                .disabled(saveRequested || session.driver.lastActivation == nil)
                if saved {
                    Text("Saved. Reopen the app with the same snapshot URL.")
                }
            }
            .routerStateRestoration(session.driver)
            .task(id: saveRequested) {
                guard saveRequested else { return }
                defer { saveRequested = false }
                do {
                    try await session.driver.save()
                    saved = true
                } catch {
                    // The driver publishes the error through status below.
                    saved = false
                }
            }
        case .failure:
            Text("The restored state cannot be rendered by this tab catalog.")
        }
    }
}

private struct TabRestorationResultView: View {
    let driver: RouterRestorationDriver<RestorableTabRoute>

    var body: some View {
        VStack {
            switch driver.status {
            case .inactive, .loading:
                ProgressView("Restoring navigation")
            case .saving:
                ProgressView("Saving navigation")
            case .failed(let message):
                Text("Snapshot operation failed: \(message)")
            case .active:
                EmptyView()
            }

            switch driver.lastActivation {
            case .noSnapshot:
                Text("No saved session. Starting with the current tabs.")
            case .restored(let outcome):
                // Returning without throwing does not mean the plan committed.
                switch outcome.transition {
                case .applied:
                    Text("Saved navigation restored into the current tabs.")
                case .unchanged:
                    Text("Saved navigation already matches the current state.")
                case .rejected:
                    Text("Restoration rejected. Current navigation was kept.")
                case .deferred:
                    Text("Restoration is waiting for an application policy decision.")
                }
            case .observationResumed, .alreadyActive:
                Text("Automatic saving is active.")
            case nil:
                EmptyView()
            }
        }
        .font(.footnote)
    }
}
