import Foundation

import InnoRouterCore

/// The result of one activation and the generation that produced it.
struct RouterRestorationActivationLease<R: Route> {
    let result: RouterRestorationDriverActivation<R>
    let generation: UInt64
}

struct RouterRestorationPartialConfiguration<R: Route> {
    let validator: RouterPartialRestorationValidator<R>
    let validationTimeout: Duration?
}

/// A stored snapshot to restore, or the recovery policy's answer to storage
/// that rejected it before the codec could read it.
enum RouterInitialSnapshot<R: Route> {
    case data(Data)
    case recovered(RouterSnapshotDecodingResult<R>)
}

/// Observable lifecycle of an opt-in restoration driver.
public enum RouterRestorationDriverStatus: Sendable, Hashable {
    case inactive
    case loading
    case active
    case saving
    case failed(String)
}

/// Result of activating automatic observation and restoration.
public enum RouterRestorationDriverActivation<R: Route>: Sendable, Hashable {
    case noSnapshot
    case restored(RouterRestorationOutcome<R>)
    case observationResumed
    case alreadyActive
}

/// Which side wins when navigation is requested while a restoration driver is
/// still loading its initial snapshot. Chosen when the driver is created.
///
/// The initial load is asynchronous, so a request can arrive before the
/// snapshot does: an early deep link, a programmatic push in `onAppear`, or a
/// quick tap.
///
/// The value set is a struct with static members, not an enum, so a later
/// minor release can add an option (for example a bounded hold) without
/// breaking an exhaustive `switch`.
public struct RouterRestorationPrecedence: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case navigation
        case snapshot
    }

    let kind: Kind

    /// A navigation committed while the snapshot loads wins.
    ///
    /// The snapshot was read for a state that no longer exists, so the driver
    /// reports the initial restore as rejected with `.staleState` and saves
    /// the committed state instead. This is the default and the 7.0 behavior.
    public static let navigation = RouterRestorationPrecedence(kind: .navigation)

    /// The Store commits nothing until the initial restore has run, so
    /// navigation that a view requests while the snapshot loads cannot
    /// displace the previous session.
    ///
    /// The driver holds the Store's execution lane from the moment activation
    /// starts until its restore request runs: through the storage load,
    /// decoding, migration, tab reconciliation, and partial-restoration
    /// validation. Requests admitted meanwhile follow the Store's scheduling
    /// policy exactly as they would behind any running request: `.serialize`
    /// queues them in order, `.rejectWhileBusy` rejects them as busy, naming
    /// the reserved restore transition.
    ///
    /// When the storage has no snapshot, the load or decoding fails, or the
    /// driver stops, nothing replaced the scopes and the queued requests run
    /// on the current state. After an applied or unchanged restore, they run
    /// under the ordinary rules:
    ///
    /// - A request from a `RouterScope` or a view's router, including a
    ///   host's own deep-link handling and SwiftUI's navigation bindings, was
    ///   written for the scope the restore replaced. It is rejected as an
    ///   expired scope, as after any restore, and an awaited presentation is
    ///   cancelled. A launch deep link handled by a host is therefore dropped,
    ///   with a rejected `RouterEvent` and a log entry.
    /// - A request sent to the Store itself is not tied to a scope. It runs
    ///   after the restore and can change or replace the restored state:
    ///   `perform`, `dispatch`, `transaction`, `replaceHost`,
    ///   `restore(from:using:)`, and link handling through
    ///   `handle(_:using:)` or a pending-link resume, whose default plan
    ///   replaces the whole state. Store requests that capture a scope or a
    ///   revision when they are made, such as `replaceSubtree`, `present`,
    ///   tab-topology or partial restores, and history moves, are rejected or
    ///   cancelled instead.
    ///
    /// Limits:
    ///
    /// - Nothing commits during the hold. Keep the storage's load bounded and
    ///   give a partial-restoration validator a `validationTimeout`. A
    ///   validator must not await navigation on the same Store. A stopped
    ///   activation whose load is still blocking delays the next activation's
    ///   load, and the hold with it.
    /// - If a policy or authorization defers or rejects the restoration
    ///   transition, the hold ends with that outcome: the queued requests run
    ///   on the state before the snapshot, and the driver saves what they
    ///   commit. A deferred restore resumed with the default
    ///   `.requireUnchangedState` is then rejected as stale.
    /// - A request that was already executing or queued when activation
    ///   started keeps its place; that activation then behaves as
    ///   ``navigation``.
    public static let snapshot = RouterRestorationPrecedence(kind: .snapshot)
}
