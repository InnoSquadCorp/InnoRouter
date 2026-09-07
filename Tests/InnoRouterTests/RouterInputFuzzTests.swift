import Foundation
import Testing

import InnoRouterDeepLink

@Suite("Deep-link input mutation")
struct RouterInputFuzzTests {
    @Test("Deterministic malformed URL corpus always fails closed")
    func mutatedURLsFailClosed() {
        let matcher = DeepLinkMatcher<Int>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: .init(
                    maxURLLength: 256,
                    maxPathSegments: 8,
                    maxQueryItems: 8
                )
            )
        ) {
            DeepLinkMapping("/items/:id") { parameters in
                parameters.firstValue(forName: "id", as: Int.self)
            }
            DeepLinkMapping("/files/*") { _ in 999 }
        }

        var generator = ByteMutationGenerator(seed: 0xF022_CAFE)
        let corpus = [
            "app://host/items/42",
            "https://host/files/readme",
            "app://host/%",
            "app://host/items/%FF",
            "app://host/items/42?q=1&q=2",
            "not a URL",
            "https://[",
            "🧭://경로/항목",
        ]

        for index in 0..<5_000 {
            let source = corpus[index % corpus.count]
            let mutated = generator.mutate(source, maximumOperations: 8)
            let result = matcher.match(mutated)
            #expect(result == nil || result == 999 || result.map { $0 >= 0 } == true)
        }
    }
}

private struct ByteMutationGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func mutate(_ input: String, maximumOperations: Int) -> String {
        var bytes = Array(input.utf8)
        let operations = Int(next() % UInt64(maximumOperations + 1))
        for _ in 0..<operations {
            switch next() % 4 {
            case 0 where !bytes.isEmpty:
                bytes.remove(at: Int(next() % UInt64(bytes.count)))
            case 1 where !bytes.isEmpty:
                bytes[Int(next() % UInt64(bytes.count))] = mutationByte()
            case 2 where bytes.count < 512:
                bytes.insert(mutationByte(), at: Int(next() % UInt64(bytes.count + 1)))
            default:
                if bytes.count < 510 {
                    bytes.append(contentsOf: [0x25, hexDigit(), hexDigit()])
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func mutationByte() -> UInt8 {
        let corpus: [UInt8] = [
            0x00, 0x20, 0x23, 0x25, 0x26, 0x2F, 0x3A, 0x3D,
            0x3F, 0x5B, 0x5D, 0x7F, 0xC0, 0xFF,
        ]
        return corpus[Int(next() % UInt64(corpus.count))]
    }

    private mutating func hexDigit() -> UInt8 {
        let digits = Array("0123456789ABCDEF".utf8)
        return digits[Int(next() % UInt64(digits.count))]
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
