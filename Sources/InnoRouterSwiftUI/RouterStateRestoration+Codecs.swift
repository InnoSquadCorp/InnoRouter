import Foundation
import InnoRouterCore

public extension RouterRestorationDriver {
    /// Uses the legacy recursive Codable format and its explicit recovery policy.
    convenience init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail,
        saveDebounce: Duration = .milliseconds(250)
    ) where R: Codable {
        self.init(
            store: store, codecExecutor: .init(codec: codec, resourceBudget: store.resourceBudget), storage: storage,
            recovery: recovery, saveDebounce: saveDebounce
        )
    }

    /// Reconciles a legacy snapshot against the application's current tab topology.
    convenience init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail,
        tabTopology: RouterTabRestorationTopology,
        saveDebounce: Duration = .milliseconds(250)
    ) where R: Codable {
        self.init(
            store: store, codecExecutor: .init(codec: codec, resourceBudget: store.resourceBudget), storage: storage,
            recovery: recovery, tabTopology: tabTopology, saveDebounce: saveDebounce
        )
    }

    /// Runs the existing bounded partial planner for a legacy snapshot.
    convenience init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        validator: RouterPartialRestorationValidator<R>,
        validationTimeout: Duration? = nil,
        tabTopology: RouterTabRestorationTopology? = nil,
        saveDebounce: Duration = .milliseconds(250)
    ) where R: Codable {
        self.init(
            store: store, codecExecutor: .init(codec: codec, resourceBudget: store.resourceBudget), storage: storage,
            tabTopology: tabTopology, validator: validator,
            validationTimeout: validationTimeout, saveDebounce: saveDebounce
        )
    }

    /// Persists stable-key graph DTOs through the same Store, byte executor and
    /// durability ordering as legacy persistence. Routes need not be Codable.
    ///
    /// Decode errors preserve the stored bytes and are never retried as legacy
    /// data. Tab reconciliation and optional route validation precede the normal
    /// host, current authorization, policy and lifetime admission. Restoration
    /// creates new runtime ownership; persisted IDs never resurrect old waiters.
    convenience init(
        store: RouterStore<R>,
        graphCodec: RouterGraphSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        tabTopology: RouterTabRestorationTopology? = nil,
        validator: RouterPartialRestorationValidator<R>? = nil,
        validationTimeout: Duration? = nil,
        saveDebounce: Duration = .milliseconds(250)
    ) {
        self.init(
            store: store, codecExecutor: .init(graphCodec: graphCodec, resourceBudget: store.resourceBudget), storage: storage,
            tabTopology: tabTopology, validator: validator,
            validationTimeout: validationTimeout, saveDebounce: saveDebounce
        )
    }
}
