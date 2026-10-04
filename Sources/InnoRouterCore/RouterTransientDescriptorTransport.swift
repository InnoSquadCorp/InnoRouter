import Foundation

/// Capability owned by the bounded Testing codec. Persistence codecs always
/// create fresh contexts and cannot opt in by guessing a public user-info key.
package enum RouterTransientDescriptorTransport {
    private final class Marker: Sendable {}
    private static let marker = Marker()
    private static let key = CodingUserInfoKey(rawValue: "InnoRouter.testing.transientDescriptors")!

    package static func isEnabled(_ userInfo: [CodingUserInfoKey: Any]) -> Bool {
        guard let value = userInfo[key] as? Marker else { return false }
        return value === marker
    }

    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[key] = marker
        return encoder
    }

    package static func decoder(formatVersion: Int) -> JSONDecoder {
        let decoder = JSONDecoder()
        if formatVersion == 9 { decoder.userInfo[key] = marker }
        return decoder
    }
}
