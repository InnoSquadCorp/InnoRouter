import Foundation
import InnoRouterCore

/// Every initializer takes `initialRestorePrecedence`, which decides what
/// happens to navigation requested while the initial snapshot loads. The
/// default, ``RouterRestorationPrecedence/navigation``, is the 7.0 behavior.
public extension RouterRestorationDriver {
    /// Uses the legacy recursive Codable format and its explicit recovery policy.
    convenience init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail,
        saveDebounce: Duration = .milliseconds(250),
        initialRestorePrecedence: RouterRestorationPrecedence = .navigation
    ) where R: Codable {
        self.init(
            store: store, codecExecutor: .init(codec: codec, resourceBudget: store.resourceBudget), storage: storage,
            recovery: recovery, saveDebounce: saveDebounce,
            initialRestorePrecedence: initialRestorePrecedence
        )
    }

    /// Reconciles a legacy snapshot against the application's current tab topology.
    convenience init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail,
        tabTopology: RouterTabRestorationTopology,
        saveDebounce: Duration = .milliseconds(250),
        initialRestorePrecedence: RouterRestorationPrecedence = .navigation
    ) where R: Codable {
        self.init(
            store: store, codecExecutor: .init(codec: codec, resourceBudget: store.resourceBudget), storage: storage,
            recovery: recovery, tabTopology: tabTopology, saveDebounce: saveDebounce,
            initialRestorePrecedence: initialRestorePrecedence
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
        saveDebounce: Duration = .milliseconds(250),
        initialRestorePrecedence: RouterRestorationPrecedence = .navigation
    ) where R: Codable {
        self.init(
            store: store, codecExecutor: .init(codec: codec, resourceBudget: store.resourceBudget), storage: storage,
            tabTopology: tabTopology, validator: validator,
            validationTimeout: validationTimeout, saveDebounce: saveDebounce,
            initialRestorePrecedence: initialRestorePrecedence
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
        saveDebounce: Duration = .milliseconds(250),
        initialRestorePrecedence: RouterRestorationPrecedence = .navigation
    ) {
        self.init(
            store: store, codecExecutor: .init(graphCodec: graphCodec, resourceBudget: store.resourceBudget), storage: storage,
            tabTopology: tabTopology, validator: validator,
            validationTimeout: validationTimeout, saveDebounce: saveDebounce,
            initialRestorePrecedence: initialRestorePrecedence
        )
    }
}
