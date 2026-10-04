import Foundation
import InnoRouterCore

public extension RouterFileSnapshotStorage {
    /// Uses the shared persistence byte cap before file reads and atomic writes.
    init(fileURL: URL, resourceBudget: RouterResourceBudget) throws {
        try resourceBudget.validateConfiguration()
        try self.init(fileURL: fileURL, maximumByteCount: resourceBudget.snapshot.maximumEncodedBytes)
    }
}

public extension RouterFilePendingLinkStorage {
    /// Pending transport owns a separate file but uses the same encoded cap.
    init(fileURL: URL, resourceBudget: RouterResourceBudget) throws {
        try resourceBudget.validateConfiguration()
        try self.init(fileURL: fileURL, maximumByteCount: resourceBudget.snapshot.maximumEncodedBytes)
    }
}
