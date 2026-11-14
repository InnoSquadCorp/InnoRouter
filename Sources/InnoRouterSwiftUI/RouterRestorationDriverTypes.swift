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
/// still loading its initial snapshot.
///
/// The initial load is asynchronous, so a request can arrive before the
/// snapshot does: an early deep link, a programmatic push in `onAppear`, or a
/// quick tap. The two cases state what that request means.
public enum RouterRestorationPrecedence: Sendable, Hashable {
    /// A navigation committed while the snapshot loads wins.
    ///
    /// The snapshot was read for a state that no longer exists, so the driver
    /// reports the initial restore as rejected with `.staleState` and saves
    /// the committed state instead. This is the default.
    case navigation
    /// The snapshot is applied before any navigation requested while it
    /// loads, so that navigation never displaces the previous session.
    ///
    /// The driver holds the Store's execution lane from the moment activation
    /// starts until the restore request runs, the storage reports no
    /// snapshot, or activation fails or stops. Requests admitted meanwhile
    /// follow the Store's scheduling policy exactly as they would behind any
    /// running request: `.serialize` queues them in order, `.rejectWhileBusy`
    /// rejects them as busy. Once the snapshot is applied, the queued
    /// requests run:
    ///
    /// - A request sent to the Store itself runs on the restored state.
    /// - A request from a `RouterScope` or a view's router, including a
    ///   host's own deep-link handling and SwiftUI's navigation bindings, was
    ///   written for the scope the restore replaced. It is rejected as an
    ///   expired scope, as after any restore, and an awaiting typed
    ///   presentation is cancelled. To navigate on top of the restored state
    ///   at launch, send the request to the Store, or wait until the
    ///   driver's `status` leaves `.loading`.
    ///
    /// Limits:
    ///
    /// - Nothing commits during the hold, so keep the storage's load bounded.
    ///   A stopped activation whose load is still blocking delays the next
    ///   activation's load, and the hold with it.
    /// - A policy that defers the restoration transition ends the hold with
    ///   the deferral; the queued requests then run before the snapshot.
    /// - An exact plan sent to the Store during the hold (`perform(.apply)`,
    ///   `transaction`) replaces the restored state when it runs.
    /// - A partial-restoration validator must not await navigation on the
    ///   same Store.
    ///
    /// A request that was already executing when activation started keeps its
    /// place; that activation then behaves as ``navigation``.
    case snapshot
}
