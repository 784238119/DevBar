import Foundation

public struct AppPaths: Sendable {
    public let applicationSupport: URL

    public init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport.standardizedFileURL
    }

    public init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        self.init(applicationSupport: base.appending(path: "DevBar", directoryHint: .isDirectory))
    }

    public var configURL: URL {
        applicationSupport.appending(path: "config.json", directoryHint: .notDirectory)
    }

    public var backupConfigURL: URL {
        applicationSupport.appending(path: "config.json.bak", directoryHint: .notDirectory)
    }

    public var logsRootURL: URL {
        applicationSupport.appending(path: "Logs", directoryHint: .isDirectory)
    }
}
