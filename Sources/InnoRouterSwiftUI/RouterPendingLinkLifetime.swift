import Foundation
import InnoRouterCore
import InnoRouterDeepLink

/// Slot-owned metadata survives persistence-driver replacement, but is neither
/// part of public link equality nor a new mutable navigation authority.
@MainActor
package final class RouterPendingLinkLifetimeState {
    package let originatedAt: Date
    package private(set) var lastObservedAt: Date
    private let lifetime: Duration?
    private let now: @Sendable () -> Date

    package init(originatedAt: Date, lastObservedAt: Date, lifetime: Duration?, now: @escaping @Sendable () -> Date) {
        self.originatedAt = originatedAt
        self.lastObservedAt = lastObservedAt
        self.lifetime = lifetime
        self.now = now
    }

    @MainActor
    package func validate<R: Route>(link: PendingRouterLink<R>) throws -> RouterDurablePendingLink<R> {
        let date = now()
        let previous = lastObservedAt
        // Even an expired observation advances the high-water mark. A later
        // wall-clock reversal must not make an already-expired intent live again.
        if date.timeIntervalSinceReferenceDate.isFinite, date >= previous { lastObservedAt = date }
        try RouterPendingLinkCodec<R>.validateTimestamps(origin: originatedAt, observed: previous, now: date, lifetime: lifetime)
        return .init(link: link, originatedAt: originatedAt, lastObservedAt: lastObservedAt)
    }
}
