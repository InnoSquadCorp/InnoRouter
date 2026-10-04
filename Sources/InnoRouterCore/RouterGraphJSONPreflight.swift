import Foundation

/// Graph-specific error boundary for the shared iterative JSON checker.
enum RouterGraphJSONPreflight {
    static func validate(_ data: Data, maximumBytes: Int, limits: RouterGraphSnapshotLimits, byteName: String) throws {
        do {
            try RouterJSONPreflight.validate(
                data, maximumBytes: maximumBytes, maximumDepth: limits.maximumJSONDepth,
                maximumTokens: limits.maximumJSONTokens, byteName: byteName
            )
        } catch let error as RouterJSONPreflightError {
            switch error {
            case .malformedJSON: throw RouterGraphSnapshotError.malformedJSON
            case .duplicateJSONKey: throw RouterGraphSnapshotError.duplicateJSONKey
            case .limitExceeded(let name, let actual, let maximum):
                throw RouterGraphSnapshotError.limitExceeded(name: name, actual: actual, maximum: maximum)
            }
        }
    }

    static func check(_ actual: Int, maximum: Int, name: String) throws {
        guard actual <= maximum else {
            throw RouterGraphSnapshotError.limitExceeded(name: name, actual: actual, maximum: maximum)
        }
    }
}
