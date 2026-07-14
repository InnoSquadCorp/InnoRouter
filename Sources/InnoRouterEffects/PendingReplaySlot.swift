// MARK: - PendingReplaySlot.swift
// InnoRouterEffects - identity-safe pending replay storage
// Copyright © 2026 Inno Squad. All rights reserved.

/// Distinguishes replacement requests by revision rather than value equality.
///
/// A deferred deep link may be replaced with an equal URL and plan while an
/// asynchronous authorization probe is suspended. The replacement is still a
/// new request and must not be consumed by the older probe.
@MainActor
struct PendingReplaySlot<Value: Sendable> {
    struct Ticket: Sendable {
        fileprivate let revision: UInt64
        let value: Value
    }

    enum Resolution: Sendable {
        case noPending
        case pending(Value)
        case replay(Value)
    }

    private(set) var current: Value?
    private var revision: UInt64 = 0

    mutating func replace(with value: Value?) {
        revision &+= 1
        current = value
    }

    func capture() -> Ticket? {
        current.map { Ticket(revision: revision, value: $0) }
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.revision == revision
    }

    mutating func resolve(_ ticket: Ticket, allowReplay: Bool) -> Resolution {
        guard isCurrent(ticket) else {
            return current.map(Resolution.pending) ?? .noPending
        }
        guard allowReplay else {
            return .pending(ticket.value)
        }

        replace(with: nil)
        return .replay(ticket.value)
    }
}
