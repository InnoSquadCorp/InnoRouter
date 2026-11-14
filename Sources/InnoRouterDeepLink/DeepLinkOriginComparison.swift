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

    /// Returns whether `url` has no credentials or port and both its scheme
    /// and host exactly match one declared value.
    static func admits(_ url: URL, schemes: [String], hosts: [String]) -> Bool {
        guard !carriesCredentials(url), url.port == nil,
              let scheme = url.scheme, contains(schemes, scheme),
              let host = url.host, contains(hosts, host) else {
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
    /// only. Unicode case folding is never applied.
    static func admitsOrigin(
        of url: URL,
        schemes: [String],
        hosts: [String]
    ) -> Bool {
        DeepLinkOriginComparison.admits(url, schemes: schemes, hosts: hosts)
    }
}
