import Foundation
import Testing

@testable import InnoRouterCore

@Suite("JSON key decoding fast path")
struct RouterJSONKeyDecoderTests {
    @Test("Plain ASCII keys avoid Foundation without changing their values")
    func plainASCIIKeysAvoidFoundation() throws {
        for text in [#""""#, #""value""#, #"" space / ~ ! [] {} : , ""#] {
            let bytes = Array(text.utf8)
            var fallbackCalls = 0
            let key = try RouterJSONKeyDecoder.decode(bytes[...]) { data in
                fallbackCalls += 1
                return try JSONDecoder().decode(String.self, from: data)
            }
            #expect(key == (try JSONDecoder().decode(String.self, from: Data(bytes))))
            if fallbackCalls != 0 {
                Issue.record("ASCII key fast path invoked Foundation")
            }
        }
    }

    @Test("Escaped and Unicode keys retain Foundation decoding")
    func escapedAndUnicodeKeys() throws {
        for text in [#""\u0076alue""#, #""a\"b""#, #""a\\b""#, #""a\nb""#, #""한글""#, #""é""#, #""e\u0301""#] {
            let bytes = Array(text.utf8)
            var fallbackCalls = 0
            let key = try RouterJSONKeyDecoder.decode(bytes[...]) { data in
                fallbackCalls += 1
                return try JSONDecoder().decode(String.self, from: data)
            }
            #expect(key == (try JSONDecoder().decode(String.self, from: Data(bytes))))
            #expect(fallbackCalls == 1)
        }
    }

    @Test("Malformed scalar input cannot enter the ASCII fast path")
    func malformedKeysUseTheExistingDecoder() {
        for bytes in [Array("value".utf8), [34, 1, 34], [34, 255, 34], Array(#""\uD800""#.utf8), [34, 97, 34, 98, 34]] {
            var fallbackCalls = 0
            #expect(throws: (any Error).self) {
                try RouterJSONKeyDecoder.decode(bytes[...]) { data in
                    fallbackCalls += 1
                    return try JSONDecoder().decode(String.self, from: data)
                }
            }
            #expect(fallbackCalls == 1)
        }
    }

    @Test("Logical key reservations reject before either decoding path")
    func budgetAdmissionPrecedesDecoding() {
        for text in [#""value""#, #""\u0076alue""#] {
            let bytes = Array(text.utf8)
            var work = RouterJSONWorkBudget(limits: .init(maximumWorkUnits: .max, maximumKeyDecodes: 0))
            var enteredDecoder = false
            #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 1, maximum: 0)) {
                try work.withKeyDecode(byteCount: bytes.count) {
                    enteredDecoder = true
                    return try RouterJSONKeyDecoder.decode(bytes[...]) { try JSONDecoder().decode(String.self, from: $0) }
                }
            }
            #expect(!enteredDecoder)
        }
    }
}
