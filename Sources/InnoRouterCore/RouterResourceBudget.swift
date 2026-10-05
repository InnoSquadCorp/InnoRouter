import Foundation

/// One explicit configuration for the library's independently owned resources.
/// Values are provisional starting points, not calibrated release guarantees.
/// Each owner must enforce its relevant fields at admission; constructing this
/// value alone does not install limits on an existing Store or codec.
///
/// State admission bounds structural counts plus built-in metadata: repeated
/// identifier/name UTF-8 bytes use the payload-byte cap, and detent/badge elements
/// use the JSON-token cap. These are logical limits, not runtime bytes or RSS.
/// Opaque Route memory is not measured. Payload byte limits also apply at codec
/// boundaries. Timing remains cooperative, not preemptive; timed-out work retains
/// its slot until actual exit.
public struct RouterResourceBudget: Hashable, Sendable {
    public let snapshot: RouterGraphSnapshotLimits
    /// The queue owner enforces this cap using its configured overflow strategy;
    /// resource admission never partially applies or truncates an individual request.
    public let maximumPendingRequests: Int
    /// The deferral owner counts unresolved entries until their terminal removal.
    public let maximumDeferrals: Int
    /// Nil opts out. Zero admits no new work. Logical timeout does not free a slot.
    public let maximumActivePolicyOperations: Int?
    /// Nil opts out. The owning Store shares this cap across restoration sources.
    public let maximumActiveRestorationOperations: Int?
    /// Nil opts out of the cooperative deadline, not other admission limits.
    public let policyTimeout: Duration?
    public let deferralLifetime: Duration?
    public let durablePendingLifetime: Duration?
    /// Recursive legacy JSON has a different wire depth from the flat graph.
    public let legacyJSONDepth: Int
    public let scenarioImport: RouterJSONImportBudget
    public let inspectorImport: RouterJSONImportBudget
    public let maximumScenarioSteps: Int
    public let maximumInspectorEntries: Int
    public let maximumRecordedInspectorEntries: Int
    public let maximumInspectorExportBytes: Int
    /// Nil derives a finite logical cap from the input's byte/token limits.
    /// These are algorithmic accounting units, not CPU-time or RSS estimates.
    public let maximumJSONWorkUnits: Int?
    public let maximumJSONKeyDecodes: Int?

    public init(
        snapshot: RouterGraphSnapshotLimits = .provisional,
        maximumPendingRequests: Int = 256,
        maximumDeferrals: Int = 64,
        maximumActivePolicyOperations: Int? = 64,
        maximumActiveRestorationOperations: Int? = 8,
        policyTimeout: Duration? = .seconds(30),
        deferralLifetime: Duration? = .seconds(15 * 60),
        durablePendingLifetime: Duration? = .seconds(24 * 60 * 60),
        legacyJSONDepth: Int = 128,
        scenarioImport: RouterJSONImportBudget = .scenario,
        inspectorImport: RouterJSONImportBudget = .inspector,
        maximumScenarioSteps: Int = 2_000,
        maximumInspectorEntries: Int = 5_000,
        maximumRecordedInspectorEntries: Int = 500,
        maximumInspectorExportBytes: Int = 8 * 1_024 * 1_024,
        maximumJSONWorkUnits: Int? = nil,
        maximumJSONKeyDecodes: Int? = nil
    ) {
        self.snapshot = snapshot
        self.maximumPendingRequests = maximumPendingRequests
        self.maximumDeferrals = maximumDeferrals
        self.maximumActivePolicyOperations = maximumActivePolicyOperations
        self.maximumActiveRestorationOperations = maximumActiveRestorationOperations
        self.policyTimeout = policyTimeout
        self.deferralLifetime = deferralLifetime
        self.durablePendingLifetime = durablePendingLifetime
        self.legacyJSONDepth = legacyJSONDepth
        self.scenarioImport = scenarioImport
        self.inspectorImport = inspectorImport
        self.maximumScenarioSteps = maximumScenarioSteps
        self.maximumInspectorEntries = maximumInspectorEntries
        self.maximumRecordedInspectorEntries = maximumRecordedInspectorEntries
        self.maximumInspectorExportBytes = maximumInspectorExportBytes
        self.maximumJSONWorkUnits = maximumJSONWorkUnits
        self.maximumJSONKeyDecodes = maximumJSONKeyDecodes
    }

    public static let provisional = Self()

    /// Explicitly opts out of finite execution/retention deadlines and uses
    /// Int.max structure/byte limits. This is outside bounded-resource promises.
    public static let unlimited = Self(
        snapshot: try! .init(
            maximumEncodedBytes: .max, maximumPayloadBytes: .max,
            maximumRoutePayloadBytes: .max, maximumJSONDepth: .max,
            maximumJSONTokens: .max, maximumNodes: .max, maximumRoutes: .max,
            maximumPresentations: .max, maximumGraphDepth: .max,
            maximumStackPath: .max, maximumPresentationDepth: .max, maximumWindows: .max
        ),
        maximumPendingRequests: .max, maximumDeferrals: .max,
        maximumActivePolicyOperations: nil, maximumActiveRestorationOperations: nil,
        policyTimeout: nil, deferralLifetime: nil, durablePendingLifetime: nil,
        legacyJSONDepth: .max, scenarioImport: .unlimited, inspectorImport: .unlimited,
        maximumScenarioSteps: .max, maximumInspectorEntries: .max,
        maximumRecordedInspectorEntries: .max, maximumInspectorExportBytes: .max,
        maximumJSONWorkUnits: .max, maximumJSONKeyDecodes: .max
    )

    /// Shared fail-closed arithmetic for library resource owners. Check before
    /// allocating or starting the admitted operation. Int.max is a diagnostic
    /// sentinel if an invalid count or overflow makes the true total unavailable;
    /// overflow rejects even when the configured maximum is itself Int.max.
    package static func addingResourceCount(
        _ value: Int, _ increment: Int, maximum: Int, resource: String
    ) throws(RouterResourceLimitFailure) -> Int {
        let (next, overflow) = value.addingReportingOverflow(increment)
        guard value >= 0, increment >= 0, maximum >= 0, !overflow, next <= maximum else {
            throw RouterResourceLimitFailure(
                resource: resource,
                actual: value < 0 || increment < 0 || overflow ? .max : next,
                maximum: maximum
            )
        }
        return next
    }
}

/// Extensible resource rejection shared by state and adapters. Library-created
/// resource names contain structural labels only, never route values or URLs.
public struct RouterResourceLimitFailure: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public struct Code: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let exceeded = Self(rawValue: "innorouter.resource.limitExceeded")
        public static let invalidConfiguration = Self(rawValue: "innorouter.resource.invalidConfiguration")
    }
    public let code: Code
    public let resource: String
    public let actual: Int
    public let maximum: Int
    /// Present for configuration range failures. Resource excess uses only
    /// `maximum`; invalid configuration reports the complete permitted range.
    /// Duration failures name the offending seconds/attoseconds component.
    public let minimum: Int?

    public init(
        code: Code = .exceeded, resource: String, actual: Int,
        maximum: Int, minimum: Int? = nil
    ) {
        self.code = code
        self.resource = resource
        self.actual = actual
        self.maximum = maximum
        self.minimum = minimum
    }
    public var description: String { code.rawValue }
}

/// Transport-owner input limits. Separate defaults retain each format's wire
/// shape and retention role; a larger Inspector bundle is not a larger snapshot.
public struct RouterJSONImportBudget: Hashable, Sendable {
    public let maximumEncodedBytes: Int
    public let maximumDepth: Int
    public let maximumTokens: Int
    public init(maximumEncodedBytes: Int, maximumDepth: Int, maximumTokens: Int) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDepth = maximumDepth
        self.maximumTokens = maximumTokens
    }
    public static let scenario = Self(maximumEncodedBytes: 2 * 1_024 * 1_024, maximumDepth: 64, maximumTokens: 131_072)
    public static let inspector = Self(maximumEncodedBytes: 8 * 1_024 * 1_024, maximumDepth: 64, maximumTokens: 524_288)
    public static let unlimited = Self(maximumEncodedBytes: .max, maximumDepth: .max, maximumTokens: .max)
}
