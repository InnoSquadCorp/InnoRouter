import Foundation

/// Parses a string captured from a deep-link path or query item into a typed value.
public protocol DeepLinkParameterValue: Sendable {
    /// Returns a typed value for a raw deep-link parameter string, or `nil`
    /// when the value cannot be represented by the conforming type.
    static func parseDeepLinkParameter(_ value: String) -> Self?
}

extension String: DeepLinkParameterValue {
    /// Returns the captured value unchanged.
    public static func parseDeepLinkParameter(_ value: String) -> String? {
        value
    }
}

extension Int: DeepLinkParameterValue {
    /// Parses a base-10 signed integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int? {
        Int(value)
    }
}

extension Int8: DeepLinkParameterValue {
    /// Parses a base-10 signed 8-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int8? {
        Int8(value)
    }
}

extension Int16: DeepLinkParameterValue {
    /// Parses a base-10 signed 16-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int16? {
        Int16(value)
    }
}

extension Int32: DeepLinkParameterValue {
    /// Parses a base-10 signed 32-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int32? {
        Int32(value)
    }
}

extension Int64: DeepLinkParameterValue {
    /// Parses a base-10 signed 64-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int64? {
        Int64(value)
    }
}

extension UInt: DeepLinkParameterValue {
    /// Parses a base-10 unsigned integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt? {
        UInt(value)
    }
}

extension UInt8: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 8-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt8? {
        UInt8(value)
    }
}

extension UInt16: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 16-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt16? {
        UInt16(value)
    }
}

extension UInt32: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 32-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt32? {
        UInt32(value)
    }
}

extension UInt64: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 64-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt64? {
        UInt64(value)
    }
}

extension Double: DeepLinkParameterValue {
    /// Parses a double-precision floating-point value from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Double? {
        Double(value)
    }
}

extension Float: DeepLinkParameterValue {
    /// Parses a single-precision floating-point value from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Float? {
        Float(value)
    }
}

extension Bool: DeepLinkParameterValue {
    /// Parses Swift's standard Boolean literals from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Bool? {
        Bool(value)
    }
}

extension UUID: DeepLinkParameterValue {
    /// Parses a UUID from the captured value's string representation.
    public static func parseDeepLinkParameter(_ value: String) -> UUID? {
        UUID(uuidString: value)
    }
}

public struct DeepLinkParameters: Sendable, Equatable {
    public let valuesByName: [String: [String]]

    public func firstValue(forName name: String) -> String? {
        valuesByName[name]?.first
    }

    /// Returns the first captured value for `name` parsed as `Value`.
    ///
    /// Returns `nil` when the parameter is missing or the first captured
    /// string cannot be represented by `Value`.
    public func firstValue<Value: DeepLinkParameterValue>(
        forName name: String,
        as type: Value.Type = Value.self
    ) -> Value? {
        _ = type
        guard let value = firstValue(forName: name) else { return nil }
        return Value.parseDeepLinkParameter(value)
    }

    public func values(forName name: String) -> [String] {
        valuesByName[name] ?? []
    }

    /// Returns all captured values for `name` that can be parsed as `Value`.
    ///
    /// Missing parameters return an empty array. Individual values that cannot
    /// be represented by `Value` are skipped.
    public func values<Value: DeepLinkParameterValue>(
        forName name: String,
        as type: Value.Type = Value.self
    ) -> [Value] {
        _ = type
        return values(forName: name).compactMap(Value.parseDeepLinkParameter)
    }
}
