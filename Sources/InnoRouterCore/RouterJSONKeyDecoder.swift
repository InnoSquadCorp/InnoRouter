import Foundation

/// Decode one isolated JSON object key after reserving its logical work budget.
/// Plain ASCII keys need no Foundation parser. All other spellings retain the
/// existing decoder, including escapes, Unicode, and malformed scalar input.
package enum RouterJSONKeyDecoder {
    package static func decode(
        _ bytes: ArraySlice<UInt8>, fallback: (Data) throws -> String
    ) rethrows -> String {
        if bytes.count >= 2, bytes.first == 34, bytes.last == 34 {
            let contents = bytes.dropFirst().dropLast()
            if contents.allSatisfy({ $0 >= 32 && $0 < 128 && $0 != 34 && $0 != 92 }) {
                return String(decoding: contents, as: UTF8.self)
            }
        }
        return try fallback(Data(bytes))
    }
}
