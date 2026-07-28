import Darwin
import Foundation

public enum ConfigurationStoreError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case corruptConfigurationWithoutBackup
    case backupConfigurationInvalid
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "DevBar cannot read configuration schema version \(version). Update DevBar before opening this configuration."
        case .corruptConfigurationWithoutBackup:
            "DevBar preserved the corrupt configuration, but no valid backup is available."
        case .backupConfigurationInvalid:
            "DevBar preserved the corrupt configuration, but its backup is also invalid."
        case let .fileSystem(message):
            "DevBar could not safely save configuration: \(message)"
        }
    }
}

public actor ConfigurationStore {
    private let paths: AppPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> AppConfig {
        try ensureApplicationSupportDirectory()
        guard fileManager.fileExists(atPath: paths.configURL.path) else {
            return .empty
        }

        let primaryData: Data
        do {
            primaryData = try Data(contentsOf: paths.configURL)
        } catch {
            throw ConfigurationStoreError.fileSystem("Unable to read config.json: \(error.localizedDescription)")
        }

        do {
            return try decodeConfig(primaryData)
        } catch let error as ConfigurationStoreError {
            if case .unsupportedSchemaVersion = error {
                throw error
            }
            return try recoverFromBackup(afterPreserving: primaryData)
        } catch {
            return try recoverFromBackup(afterPreserving: primaryData)
        }
    }

    public func save(_ config: AppConfig) throws {
        guard config.schemaVersion == AppConfig.supportedSchemaVersion else {
            throw ConfigurationStoreError.unsupportedSchemaVersion(config.schemaVersion)
        }
        try ensureApplicationSupportDirectory()

        let encoded: Data
        do {
            encoded = try encoder.encode(config)
        } catch {
            throw ConfigurationStoreError.fileSystem("Unable to encode configuration: \(error.localizedDescription)")
        }

        let temporaryURL = paths.applicationSupport
            .appendingPathComponent("config.json.\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? removeIfPresent(temporaryURL) }
        try writeSynced(encoded, to: temporaryURL)

        switch try classifyCurrentMainConfiguration() {
        case .absent:
            break
        case let .corrupt(currentData):
            try preserveCorruptConfiguration(currentData)
        case let .supported(currentData):
            let nextBackupURL = paths.applicationSupport.appending(path: "config.json.bak.next", directoryHint: .notDirectory)
            defer { try? removeIfPresent(nextBackupURL) }
            try removeIfPresent(nextBackupURL)
            try writeSynced(currentData, to: nextBackupURL)
            try atomicallyRename(nextBackupURL, over: paths.backupConfigURL)
        }

        try atomicallyRename(temporaryURL, over: paths.configURL)
    }

    private func recoverFromBackup(afterPreserving corruptData: Data) throws -> AppConfig {
        try preserveCorruptConfiguration(corruptData)
        guard fileManager.fileExists(atPath: paths.backupConfigURL.path) else {
            throw ConfigurationStoreError.corruptConfigurationWithoutBackup
        }
        do {
            return try decodeConfig(Data(contentsOf: paths.backupConfigURL))
        } catch let error as ConfigurationStoreError {
            if case .unsupportedSchemaVersion = error {
                throw error
            }
            throw ConfigurationStoreError.backupConfigurationInvalid
        } catch {
            throw ConfigurationStoreError.backupConfigurationInvalid
        }
    }

    private enum CurrentMainConfiguration {
        case absent
        case supported(Data)
        case corrupt(Data)
    }

    private func classifyCurrentMainConfiguration() throws -> CurrentMainConfiguration {
        guard fileManager.fileExists(atPath: paths.configURL.path) else { return .absent }
        let currentData: Data
        do {
            currentData = try Data(contentsOf: paths.configURL)
        } catch {
            throw ConfigurationStoreError.fileSystem("Unable to read existing config.json: \(error.localizedDescription)")
        }
        do {
            _ = try decodeConfig(currentData)
        } catch let error as ConfigurationStoreError {
            if case .unsupportedSchemaVersion = error {
                throw error
            }
            return .corrupt(currentData)
        } catch {
            return .corrupt(currentData)
        }
        return .supported(currentData)
    }

    private func decodeConfig(_ data: Data) throws -> AppConfig {
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch let error as AppConfigDecodingError {
            switch error {
            case let .unsupportedSchemaVersion(version):
                throw ConfigurationStoreError.unsupportedSchemaVersion(version)
            }
        }
    }

    private func ensureApplicationSupportDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: paths.applicationSupport,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.applicationSupport.path)
        } catch {
            throw ConfigurationStoreError.fileSystem("Unable to create private Application Support directory: \(error.localizedDescription)")
        }
    }

    private func preserveCorruptConfiguration(_ data: Data) throws {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let filename = "config.json.corrupt-\(timestamp)-\(UUID().uuidString)"
        let destination = paths.applicationSupport.appendingPathComponent(filename, isDirectory: false)
        try writeSynced(data, to: destination)
    }

    private func writeSynced(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw ConfigurationStoreError.fileSystem("Unable to create \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }

        do {
            defer { close(descriptor) }
            try data.withUnsafeBytes { rawBuffer in
                var bytesWritten = 0
                while bytesWritten < rawBuffer.count {
                    let result = Darwin.write(
                        descriptor,
                        rawBuffer.baseAddress!.advanced(by: bytesWritten),
                        rawBuffer.count - bytesWritten
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw ConfigurationStoreError.fileSystem("Unable to write \(url.lastPathComponent): \(String(cString: strerror(errno)))")
                    }
                    bytesWritten += result
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ConfigurationStoreError.fileSystem("Unable to synchronize \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? removeIfPresent(url)
            throw error
        }
    }

    private func atomicallyRename(_ source: URL, over destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw ConfigurationStoreError.fileSystem("Unable to replace \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ConfigurationStoreError.fileSystem("Unable to remove stale \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
