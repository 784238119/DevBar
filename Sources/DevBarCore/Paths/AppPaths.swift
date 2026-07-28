import Foundation

public struct AppPaths: Sendable {
    public let applicationSupport: URL
    private let defaultLogsRoot: URL

    public init(applicationSupport: URL, logsRoot: URL? = nil) {
        self.applicationSupport = applicationSupport.standardizedFileURL
        defaultLogsRoot = (
            logsRoot
            ?? applicationSupport.appending(path: "Logs", directoryHint: .isDirectory)
        ).standardizedFileURL
    }

    public init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        self.init(
            applicationSupport: base.appending(path: "DevBar", directoryHint: .isDirectory),
            logsRoot: URL(
                fileURLWithPath: PreferencesConfig.defaultLogDirectory,
                isDirectory: true
            )
        )
    }

    public var configURL: URL {
        applicationSupport.appending(path: "config.json", directoryHint: .notDirectory)
    }

    public var backupConfigURL: URL {
        applicationSupport.appending(path: "config.json.bak", directoryHint: .notDirectory)
    }

    public var logsRootURL: URL {
        defaultLogsRoot
    }

    public static func logsRootURL(for preferences: PreferencesConfig) -> URL {
        URL(fileURLWithPath: preferences.logDirectory, isDirectory: true)
            .standardizedFileURL
    }

    public func logsRootURL(for preferences: PreferencesConfig) -> URL {
        preferences.logDirectory == PreferencesConfig.defaultLogDirectory
            ? logsRootURL
            : Self.logsRootURL(for: preferences)
    }
}
