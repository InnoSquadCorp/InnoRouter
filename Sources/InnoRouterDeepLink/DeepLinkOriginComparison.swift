import Foundation

/// Exact origin comparison shared by every admission path.
///
/// Schemes and hosts are compared byte for byte after folding only the ASCII
/// letters `A`–`Z`. Unicode case mapping and compatibility folding are never
/// applied, so `ß` does not equal `ss` and the Kelvin sign does not equal `k`.
/// A percent-encoded host that decodes to such a character therefore cannot be
/// admitted for an ASCII allow-list entry.
enum DeepLinkOriginComparison {
    static func matches(_ candidate: String, _ allowed: String) -> Bool {
        candidate.utf8.elementsEqual(allowed.utf8) { lhs, rhs in
            asciiLowercased(lhs) == asciiLowercased(rhs)
        }
    }

    static func contains(_ allowed: [String], _ candidate: String) -> Bool {
        allowed.contains { matches(candidate, $0) }
    }

    /// Lowercases ASCII letters and leaves every other byte untouched.
    static func asciiLowercased(_ value: String) -> String {
        var bytes = Array(value.utf8)
        for index in bytes.indices {
            bytes[index] = asciiLowercased(bytes[index])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte
    }

    /// Whether `url` carries a user or password component in any form.
    ///
    /// `URL.user` and `URL.password` decode the component and return `nil`
    /// when it is not valid UTF-8, so `https://%FF@host/` would look like a
    /// URL without credentials. The percent-encoded accessors report the
    /// component as written.
    static func carriesCredentials(_ url: URL) -> Bool {
        url.user(percentEncoded: true) != nil || url.password(percentEncoded: true) != nil
    }

    /// A way of writing an authority that `URL.host` and `URL.port` report as
    /// a plain host, so comparing those two values would not see it.
    enum AuthorityDefect: Sendable, Equatable {
        /// A port delimiter with no digits, as in `host:`. `URL.port` is
        /// `nil` for it, exactly as for a URL without a port.
        case emptyPort
        /// Square brackets around a host that is not an IPv6 address, as in
        /// `[bank.example]`. `URL.host` removes the brackets.
        case bracketedName
    }

    /// Inspects the authority as `url` spells it.
    ///
    /// Both defects are malformed input that Foundation reads leniently.
    /// Every admission path rejects them, so a URL is admitted only in the
    /// one spelling its allow-list entry describes. An IPv6 address keeps
    /// its brackets: they are how a URL has to write one.
    static func authorityDefect(of url: URL) -> AuthorityDefect? {
        let bytes = Array(url.absoluteString.utf8)
        let slash = UInt8(ascii: "/"), colon = UInt8(ascii: ":")
        // The first colon ends the scheme; an authority follows only `//`.
        guard let schemeEnd = bytes.firstIndex(of: colon),
              bytes[schemeEnd...].dropFirst().starts(with: [slash, slash]) else { return nil }
        var authority = bytes[(schemeEnd + 3)...].prefix {
            $0 != slash && $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: "#")
        }
        if let userInfoEnd = authority.lastIndex(of: UInt8(ascii: "@")) {
            authority = authority[(userInfoEnd + 1)...]
        }
        guard authority.first == UInt8(ascii: "[") else {
            return authority.last == colon ? .emptyPort : nil
        }
        guard let close = authority.firstIndex(of: UInt8(ascii: "]")),
              authority[authority.startIndex ..< close].contains(colon) else {
            return .bracketedName
        }
        return authority.last == colon ? .emptyPort : nil
    }

    /// Returns whether `url` has no credentials or port, writes its authority
    /// without an ``AuthorityDefect``, and both its scheme and host exactly
    /// match one declared value.
    static func admits(_ url: URL, schemes: [String], hosts: [String]) -> Bool {
        guard !carriesCredentials(url), url.port == nil,
              let scheme = url.scheme, contains(schemes, scheme),
              let host = url.host, contains(hosts, host),
              authorityDefect(of: url) == nil else {
            return false
        }
        return true
    }
}

public extension DeepLinkFeatureRuntime {
    /// Origin admission used by macro-generated resolvers.
    ///
    /// Returns `true` only when `url` carries no user, password, or port and
    /// its scheme and host each equal one declared value, ignoring ASCII case
    /// only. Unicode case folding is never applied. A port delimiter with no
    /// port (`host:`) and square brackets around a host that is not an IPv6
    /// address are rejected too, although `URL` reports both as the plain
    /// host.
    static func admitsOrigin(
        of url: URL,
        schemes: [String],
        hosts: [String]
    ) -> Bool {
        DeepLinkOriginComparison.admits(url, schemes: schemes, hosts: hosts)
    }
}
