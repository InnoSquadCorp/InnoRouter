package enum RoutePatternDiagnostic: Sendable, Equatable {
    case nonTerminalWildcard(pattern: String, index: Int)
    case duplicatePattern(pattern: String, firstIndex: Int, duplicateIndex: Int)
    case wildcardShadowing(
        pattern: String,
        index: Int,
        shadowedPattern: String,
        shadowedIndex: Int
    )
    case parameterShadowing(
        pattern: String,
        index: Int,
        shadowedPattern: String,
        shadowedIndex: Int
    )
    case invalidParameterName(pattern: String, index: Int, name: String)
}

private enum PatternShadowKind: Sendable, Equatable {
    case wildcard
    case parameter
}

package struct RoutePattern: Sendable {
    package struct MatchResult: Sendable {
        package let parameters: [String: [String]]

        package init(parameters: [String: [String]] = [:]) {
            self.parameters = parameters
        }
    }

    fileprivate let rawPattern: String
    fileprivate let patternParts: [PatternPart]

    fileprivate enum PatternPart: Sendable, Equatable {
        case literal(String)
        case parameter(String)
        case wildcard

        func covers(_ other: Self) -> Bool {
            switch (self, other) {
            case (.literal(let lhs), .literal(let rhs)):
                return lhs == rhs
            case (.parameter, .literal), (.parameter, .parameter):
                return true
            case (.wildcard, _):
                return true
            default:
                return false
            }
        }
    }

    package init(_ pattern: String) {
        self.rawPattern = pattern
        self.patternParts = pattern
            .split(separator: "/")
            .map { part -> PatternPart in
                let stringPart = String(part)
                if stringPart.hasPrefix(":") {
                    return .parameter(String(stringPart.dropFirst()))
                } else if stringPart == "*" {
                    return .wildcard
                } else {
                    return .literal(stringPart)
                }
            }
    }

    package func match(_ path: String) -> MatchResult? {
        match(pathParts: path.split(separator: "/").map(String.init))
    }

    package func match(pathParts: [String]) -> MatchResult? {
        guard isStructurallyMatchable else { return nil }

        let hasWildcard = patternParts.contains { part in
            if case .wildcard = part { return true }
            return false
        }
        if !hasWildcard && patternParts.count != pathParts.count {
            return nil
        }

        var parameters: [String: [String]] = [:]

        for (index, patternPart) in patternParts.enumerated() {
            switch patternPart {
            case .literal(let expected):
                guard index < pathParts.count, pathParts[index] == expected else { return nil }

            case .parameter(let name):
                guard index < pathParts.count else { return nil }
                parameters[name, default: []].append(pathParts[index])

            case .wildcard:
                return MatchResult(parameters: parameters)
            }
        }

        return MatchResult(parameters: parameters)
    }

    fileprivate var normalizedPattern: String {
        "/" + patternParts.map { part in
            switch part {
            case .literal(let value):
                return value
            case .parameter:
                return ":param"
            case .wildcard:
                return "*"
            }
        }.joined(separator: "/")
    }

    fileprivate var wildcardIndex: Int? {
        patternParts.firstIndex(of: .wildcard)
    }

    fileprivate var nonTerminalWildcardIndex: Int? {
        guard let wildcardIndex, wildcardIndex != patternParts.index(before: patternParts.endIndex) else {
            return nil
        }
        return wildcardIndex
    }

    fileprivate var invalidParameterNameDiagnostics: [RoutePatternDiagnostic] {
        patternParts.enumerated().compactMap { index, part in
            guard case .parameter(let name) = part,
                  !Self.isValidParameterName(name)
            else {
                return nil
            }
            return .invalidParameterName(
                pattern: rawPattern,
                index: index,
                name: name
            )
        }
    }

    fileprivate var isStructurallyMatchable: Bool {
        nonTerminalWildcardIndex == nil && invalidParameterNameDiagnostics.isEmpty
    }

    private static func isValidParameterName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard isASCIILetter(first) || first == "_" else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy { scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_"
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48 ... 57).contains(scalar.value)
    }

    private func shadows(_ other: RoutePattern) -> PatternShadowKind? {
        guard nonTerminalWildcardIndex == nil else {
            return nil
        }

        if let wildcardIndex {
            guard prefixStructurallyCovers(other.patternParts, prefixLength: wildcardIndex) else {
                return nil
            }
            return .wildcard
        }

        guard patternParts.count == other.patternParts.count else {
            return nil
        }

        var sawParameterShadow = false
        for (lhs, rhs) in zip(patternParts, other.patternParts) {
            switch (lhs, rhs) {
            case (.literal(let lhsValue), .literal(let rhsValue)) where lhsValue == rhsValue:
                continue
            case (.parameter, .literal):
                sawParameterShadow = true
            case (.parameter(let lhsName), .parameter(let rhsName)):
                sawParameterShadow = sawParameterShadow || lhsName != rhsName
                continue
            default:
                return nil
            }
        }

        return sawParameterShadow ? .parameter : nil
    }

    private func prefixStructurallyCovers(
        _ otherParts: [PatternPart],
        prefixLength: Int
    ) -> Bool {
        guard otherParts.count >= prefixLength else {
            return false
        }

        for index in 0..<prefixLength {
            guard patternParts[index].covers(otherParts[index]) else {
                return false
            }
        }
        return true
    }

    package static func makeDiagnostics(
        for patterns: [RoutePattern]
    ) -> [RoutePatternDiagnostic] {
        var diagnostics: [RoutePatternDiagnostic] = []

        for index in patterns.indices {
            let pattern = patterns[index]
            if let wildcardIndex = pattern.nonTerminalWildcardIndex {
                diagnostics.append(
                    .nonTerminalWildcard(
                        pattern: pattern.normalizedPattern,
                        index: wildcardIndex
                    )
                )
            }
            diagnostics.append(contentsOf: pattern.invalidParameterNameDiagnostics)
        }

        for earlierIndex in patterns.indices {
            let earlier = patterns[earlierIndex]
            guard earlier.isStructurallyMatchable else {
                continue
            }
            for laterIndex in patterns.indices where laterIndex > earlierIndex {
                let later = patterns[laterIndex]
                guard later.isStructurallyMatchable else {
                    continue
                }

                if earlier.normalizedPattern == later.normalizedPattern {
                    diagnostics.append(
                        .duplicatePattern(
                            pattern: later.normalizedPattern,
                            firstIndex: earlierIndex,
                            duplicateIndex: laterIndex
                        )
                    )
                    continue
                }

                switch earlier.shadows(later) {
                case .wildcard?:
                    diagnostics.append(
                        .wildcardShadowing(
                            pattern: earlier.normalizedPattern,
                            index: earlierIndex,
                            shadowedPattern: later.normalizedPattern,
                            shadowedIndex: laterIndex
                        )
                    )
                case .parameter?:
                    diagnostics.append(
                        .parameterShadowing(
                            pattern: earlier.normalizedPattern,
                            index: earlierIndex,
                            shadowedPattern: later.normalizedPattern,
                            shadowedIndex: laterIndex
                        )
                    )
                case nil:
                    break
                }
            }
        }

        return diagnostics
    }

    /// Returns a stable order that places structurally narrower patterns before
    /// every broader pattern that would otherwise shadow them.
    ///
    /// Duplicate normalized patterns retain declaration order so callers can
    /// diagnose them with ``makeDiagnostics(for:)`` after applying the order.
    package static func specificityOrderedIndices(
        for patterns: [RoutePattern]
    ) -> [Int] {
        var remaining = Array(patterns.indices)
        var ordered: [Int] = []
        ordered.reserveCapacity(remaining.count)

        while !remaining.isEmpty {
            guard let position = remaining.firstIndex(where: { candidate in
                !remaining.contains(where: { other in
                    guard candidate != other,
                          patterns[candidate].normalizedPattern !=
                          patterns[other].normalizedPattern else {
                        return false
                    }
                    return patterns[candidate].shadows(patterns[other]) != nil
                })
            }) else {
                // Structural coverage is acyclic once equivalent normalized
                // patterns are excluded. Keep this fail-safe deterministic if
                // the grammar gains a new relationship in the future.
                ordered.append(contentsOf: remaining)
                break
            }

            ordered.append(remaining.remove(at: position))
        }

        return ordered
    }
}
