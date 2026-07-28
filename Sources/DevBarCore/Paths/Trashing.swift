import Foundation

/// Moves DevBar-owned data to the user's Trash instead of deleting it permanently.
public protocol Trashing: Sendable {
    func moveToTrash(_ url: URL) async throws
}

public struct FileManagerTrasher: Trashing, Sendable {
    public init() {}

    public func moveToTrash(_ url: URL) async throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
}
