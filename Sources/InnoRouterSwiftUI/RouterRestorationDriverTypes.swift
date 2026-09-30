import InnoRouterCore

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
