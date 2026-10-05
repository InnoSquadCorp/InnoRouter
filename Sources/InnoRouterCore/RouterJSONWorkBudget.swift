/// Logical admission limits for shared JSON syntax and isolated-key work.
/// These are operation/byte accounting limits, not CPU-time or RSS guarantees.
package struct RouterJSONWorkLimits: Sendable, Equatable {
    package let maximumWorkUnits: Int
    package let maximumKeyDecodes: Int

    /// Zero is useful for fail-closed admission. Negative caps also admit no work.
    package init(maximumWorkUnits: Int, maximumKeyDecodes: Int) {
        self.maximumWorkUnits = max(0, maximumWorkUnits)
        self.maximumKeyDecodes = max(0, maximumKeyDecodes)
    }

    /// A conservative accounting envelope derived from the existing input caps,
    /// not a newly calibrated release default. The ledger allows three input-byte
    /// passes, three passes per decoded key byte (including repeated root keys),
    /// required-name bytes, and parser/key bookkeeping. Each key is decoded at
    /// most twice; a JSON member needs more than two tokens, so the token cap is
    /// also a conservative invocation cap. Overflow yields a finite Int.max cap;
    /// actual work arithmetic still rejects overflow rather than wrapping.
    package static func derived(maximumBytes: Int, maximumTokens: Int) -> Self {
        let bytes = max(0, maximumBytes).multipliedReportingOverflow(by: 10)
        let tokens = max(0, maximumTokens).multipliedReportingOverflow(by: 7)
        let total = bytes.partialValue.addingReportingOverflow(tokens.partialValue)
        return .init(
            maximumWorkUnits: bytes.overflow || tokens.overflow || total.overflow ? Int.max : total.partialValue,
            maximumKeyDecodes: max(0, maximumTokens)
        )
    }
}

/// Successful logical usage. Failed reservations do not wrap or enter a decoder.
package struct RouterJSONWorkResult: Sendable, Equatable {
    package let workUnits: Int
    package let keyDecodes: Int

    package init(workUnits: Int, keyDecodes: Int) {
        self.workUnits = workUnits
        self.keyDecodes = keyDecodes
    }
}

/// New hardening: cumulative accounting across the parser and isolated key
/// decoder, rather than resetting the budget for each object or each string.
package struct RouterJSONWorkBudget: Sendable {
    package let limits: RouterJSONWorkLimits
    private var workUnits = 0
    private var keyDecodes = 0

    package init(limits: RouterJSONWorkLimits) {
        self.limits = limits
    }

    /// Continue a successful phase under the same total cap. This lets import
    /// adapters guard additional isolated-key work without resetting counters.
    package init(limits: RouterJSONWorkLimits, consumed: RouterJSONWorkResult) throws {
        self.limits = limits
        workUnits = try Self.adding(consumed.workUnits, to: 0, maximum: limits.maximumWorkUnits, name: "jsonWorkUnits")
        keyDecodes = try Self.adding(consumed.keyDecodes, to: 0, maximum: limits.maximumKeyDecodes, name: "jsonKeyDecodes")
    }

    package var result: RouterJSONWorkResult {
        .init(workUnits: workUnits, keyDecodes: keyDecodes)
    }

    /// Charge before input-dependent copies, scans, or parser-record appends.
    package mutating func charge(_ units: Int) throws {
        workUnits = try Self.adding(
            units, to: workUnits, maximum: limits.maximumWorkUnits, name: "jsonWorkUnits"
        )
    }

    /// Reserve both guards before the closure may allocate its key Data or enter
    /// Foundation. Three byte units account for the copy, scalar decode, and key
    /// lookup/insertion; one accounts for the invocation itself. This models work
    /// without making claims about Foundation's or Swift hashing's running time.
    package mutating func withKeyDecode<Value>(byteCount: Int, _ operation: () throws -> Value) throws -> Value {
        let nextDecodes = try Self.adding(
            1, to: keyDecodes, maximum: limits.maximumKeyDecodes, name: "jsonKeyDecodes"
        )
        let bytes = byteCount.multipliedReportingOverflow(by: 3)
        let units = bytes.partialValue.addingReportingOverflow(1)
        guard byteCount >= 0, !bytes.overflow, !units.overflow else {
            throw RouterJSONPreflightError.limitExceeded(
                name: "jsonWorkUnits", actual: Int.max, maximum: limits.maximumWorkUnits
            )
        }
        try charge(units.partialValue)
        keyDecodes = nextDecodes
        return try operation()
    }

    /// Admit one codec phase under both its declared cap and the remaining
    /// enclosing cap. A successful phase contributes all usage back to its
    /// enclosing operation; repeated phases cannot reset accounting.
    package mutating func withSubBudget<Value>(
        limits phaseLimits: RouterJSONWorkLimits,
        operation: (inout RouterJSONWorkBudget) throws -> Value
    ) throws -> Value {
        let prior = result
        let selected = RouterJSONWorkLimits(
            maximumWorkUnits: min(phaseLimits.maximumWorkUnits, limits.maximumWorkUnits - prior.workUnits),
            maximumKeyDecodes: min(phaseLimits.maximumKeyDecodes, limits.maximumKeyDecodes - prior.keyDecodes)
        )
        var phase = RouterJSONWorkBudget(limits: selected)
        let value = try operation(&phase)
        let used = phase.result
        let units = try Self.adding(used.workUnits, to: prior.workUnits, maximum: limits.maximumWorkUnits, name: "jsonWorkUnits")
        let decodes = try Self.adding(used.keyDecodes, to: prior.keyDecodes, maximum: limits.maximumKeyDecodes, name: "jsonKeyDecodes")
        workUnits = units
        keyDecodes = decodes
        return value
    }

    private static func adding(_ amount: Int, to current: Int, maximum: Int, name: String) throws -> Int {
        let next = current.addingReportingOverflow(amount)
        guard amount >= 0, !next.overflow, next.partialValue <= maximum else {
            // Int.max is a diagnostic sentinel when the true total cannot be
            // represented. Overflow is rejected even when the cap is Int.max.
            throw RouterJSONPreflightError.limitExceeded(
                name: name, actual: amount < 0 || next.overflow ? Int.max : next.partialValue, maximum: maximum
            )
        }
        return next.partialValue
    }
}
