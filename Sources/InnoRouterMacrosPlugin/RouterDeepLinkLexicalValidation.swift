import Foundation

func isValidDeepLinkScheme(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, isASCIILetter(first) else { return false }
    return value.unicodeScalars.dropFirst().allSatisfy { scalar in
        isASCIILetter(scalar) || isASCIIDigit(scalar) || "+-.".unicodeScalars.contains(scalar)
    }
}

func isValidDeepLinkHost(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 253,
          value.unicodeScalars.allSatisfy({ $0.isASCII }) else {
        return false
    }
    if value == "localhost" { return true }
    if value.unicodeScalars.allSatisfy({ isASCIIDigit($0) || $0 == "." }) {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && Int(octet).map { (0 ... 255).contains($0) } == true
        }
    }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in
        guard !label.isEmpty, label.count <= 63,
              let first = label.unicodeScalars.first,
              let last = label.unicodeScalars.last,
              isASCIIAlphaNumeric(first), isASCIIAlphaNumeric(last) else {
            return false
        }
        return label.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "-"
        }
    }
}

func isASCIIIdentifier(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
          isASCIILetter(first) || first == "_" else {
        return false
    }
    return value.unicodeScalars.dropFirst().allSatisfy { scalar in
        isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_"
    }
}

func isURLPathLiteralScalar(_ scalar: Unicode.Scalar) -> Bool {
    isASCIIAlphaNumeric(scalar) || "-._~".unicodeScalars.contains(scalar)
}

private func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    isASCIILetter(scalar) || isASCIIDigit(scalar)
}

private func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
}

private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    (48 ... 57).contains(scalar.value)
}
