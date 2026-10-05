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

    static func validate(
        _ data: Data, maximumBytes: Int, limits: RouterGraphSnapshotLimits,
        byteName: String, work: inout RouterJSONWorkBudget
    ) throws {
        do {
            let result = try RouterJSONPreflight.validate(
                data, maximumBytes: maximumBytes, maximumDepth: limits.maximumJSONDepth,
                maximumTokens: limits.maximumJSONTokens, byteName: byteName,
                workLimits: work.limits, consumedWork: work.result
            )
            work = try RouterJSONWorkBudget(limits: work.limits, consumed: result)
        } catch let error as RouterJSONPreflightError {
            throw failure(error)
        }
    }

    static func charge(_ count: Int, work: inout RouterJSONWorkBudget) throws {
        do { try work.charge(count) }
        catch let error as RouterJSONPreflightError { throw failure(error) }
    }

    private static func failure(_ error: RouterJSONPreflightError) -> RouterGraphSnapshotError {
        switch error {
        case .malformedJSON: .malformedJSON
        case .duplicateJSONKey: .duplicateJSONKey
        case .limitExceeded(let name, let actual, let maximum):
            .limitExceeded(name: name, actual: actual, maximum: maximum)
        }
    }

    static func check(_ actual: Int, maximum: Int, name: String) throws {
        guard actual <= maximum else {
            throw RouterGraphSnapshotError.limitExceeded(name: name, actual: actual, maximum: maximum)
        }
    }
}
