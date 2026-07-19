// MARK: - DeepLinkOriginPolicy.swift
// InnoRouterDeepLink - explicit URL-origin trust boundary
// Copyright © 2026 Inno Squad. All rights reserved.

/// Declares which URL origins a hand-rolled deep-link pipeline trusts.
///
/// Use ``allowlisted(schemes:hosts:)`` for every external URL entry point.
/// ``trustedInProcess`` is an explicit escape hatch for URLs that cannot be
/// influenced outside the current process.
public enum DeepLinkOriginPolicy: Sendable, Equatable {
    /// Admits only exact, case-insensitive scheme and host matches.
    /// Empty allowlists reject every URL and therefore remain fail-closed.
    case allowlisted(schemes: Set<String>, hosts: Set<String>)

    /// Skips scheme and host checks for URLs constructed exclusively by the
    /// current process. Do not use this for universal links, custom URL
    /// schemes, notifications, QR codes, NFC payloads, or handoff input.
    case trustedInProcess
}
