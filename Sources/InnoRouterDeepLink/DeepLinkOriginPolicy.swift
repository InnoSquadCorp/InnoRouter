// MARK: - DeepLinkOriginPolicy.swift
// InnoRouterDeepLink - explicit URL-origin trust boundary
// Copyright © 2026 Inno Squad. All rights reserved.

/// Declares which URL origins a hand-rolled deep-link pipeline trusts.
///
/// Use ``allowlisted(schemes:hosts:)`` for every external URL entry point.
/// ``trustedInProcess`` is an explicit escape hatch for URLs that cannot be
/// influenced outside the current process.
public enum DeepLinkOriginPolicy: Sendable, Equatable {
    /// Admits only scheme and host matches that are exact apart from ASCII
    /// case, and rejects user information in any form or an explicit port.
    /// Empty allowlists reject every URL and therefore remain fail-closed.
    ///
    /// Only the ASCII letters `A`–`Z` are folded; every other character is
    /// compared byte for byte, without Unicode case mapping or normalization.
    /// A `Set` merges canonically equivalent spellings of one entry, so a
    /// non-ASCII host is admitted only in the spelling the set keeps; list
    /// one spelling per host.
    case allowlisted(schemes: Set<String>, hosts: Set<String>)

    /// Skips scheme and host checks for URLs constructed exclusively by the
    /// current process. Do not use this for universal links, custom URL
    /// schemes, notifications, QR codes, NFC payloads, or handoff input.
    case trustedInProcess
}
