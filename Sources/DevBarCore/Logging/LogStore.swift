import Foundation

public struct LogStoreWarning: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case initialization
        case read
        case write
        case malformedRecord
        case delete
    }

    public let id: UUID
    public let serviceID: UUID
    public let kind: Kind
    public let message: String

    public init(id: UUID = UUID(), serviceID: UUID, kind: Kind, message: String) {
        self.id = id
        self.serviceID = serviceID
        self.kind = kind
        self.message = message
    }
}

public enum LogStoreError: Error, Equatable, Sendable, LocalizedError {
    case initializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .initializationFailed(message):
            "DevBar could not initialize service logging: \(message)"
        }
    }
}

/// The UI-facing log store. Both memory and disk receive the same terminal-sanitized
/// command output. Environment dictionaries and launch requests never enter this API.
public actor LogStore {
    public static let defaultMaximumEntries = 2_000

    private struct ServiceLocation: Sendable {
        let workspaceID: UUID
        let serviceID: UUID
        let directory: URL
    }

    private struct SanitizerKey: Hashable, Sendable {
        let serviceID: UUID
        let runID: UUID?
        let stream: LogStream
    }

    private let paths: AppPaths
    private let maximumEntries: Int
    private var maximumFileSizeBytes: Int
    private var fileCount: Int
    private let fileManager: FileManager
    private var entriesByService: [UUID: [LogEntry]] = [:]
    private var locations: [UUID: ServiceLocation] = [:]
    private var writers: [UUID: RotatingLogWriter] = [:]
    private var decoders: [SanitizerKey: UTF8StreamDecoder] = [:]
    private var sanitizers: [SanitizerKey: LogSanitizer] = [:]
    private var loadedHistory = Set<UUID>()
    private var warningKeys = Set<String>()
    private var storedWarnings: [LogStoreWarning] = []

    public init(
        paths: AppPaths,
        maximumEntries: Int = LogStore.defaultMaximumEntries,
        maximumFileSizeBytes: Int = 5 * 1_024 * 1_024,
        fileCount: Int = 3,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.maximumEntries = max(1, maximumEntries)
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.fileCount = fileCount
        self.fileManager = fileManager
    }

    /// Applies the saved rotation policy before a service starts. Writers do not hold
    /// open file descriptors, so dropping the cache safely applies the new policy to
    /// the next append without interrupting existing processes.
    public func configure(logFileSizeMiB: Int, fileCount: Int) throws {
        guard (1...100).contains(logFileSizeMiB), (1...10).contains(fileCount) else {
            throw RotatingLogWriterError.invalidConfiguration
        }
        let maximumFileSizeBytes = logFileSizeMiB * 1_024 * 1_024
        guard self.maximumFileSizeBytes != maximumFileSizeBytes || self.fileCount != fileCount else {
            return
        }
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.fileCount = fileCount
        writers.removeAll()
    }

    /// Call this before a Runner is launched. Unlike append failures, initialization
    /// failures are surfaced synchronously so a service cannot start without its logs.
    public func prepare(workspaceID: UUID, serviceID: UUID) throws {
        do {
            _ = try writer(workspaceID: workspaceID, serviceID: serviceID)
        } catch {
            throw LogStoreError.initializationFailed(error.localizedDescription)
        }
    }

    /// Sanitizes decoded output once, then persists and displays the same text.
    /// A later disk error is nonblocking: the service continues and memory still updates.
    public func append(_ entry: LogEntry, workspaceID: UUID, serviceID: UUID) {
        let key = SanitizerKey(serviceID: serviceID, runID: nil, stream: entry.stream)
        var sanitizer = sanitizers[key] ?? LogSanitizer()
        let sanitizedText = sanitizer.append(entry.text)
        sanitizers[key] = sanitizer
        guard !sanitizedText.isEmpty else { return }
        let sanitizedEntry = LogEntry(timestamp: entry.timestamp, stream: entry.stream, text: sanitizedText)
        do {
            let writer = try writer(workspaceID: workspaceID, serviceID: serviceID)
            try writer.append(sanitizedEntry)
        } catch {
            emitWarning(serviceID: serviceID, kind: .write, message: error.localizedDescription)
        }
        appendToMemory(sanitizedEntry, serviceID: serviceID)
    }

    /// The ProcessSupervisor passes raw stdout/stderr events here. Incomplete UTF-8
    /// scalars remain private to this stream until their next pipe event arrives.
    public func append(
        data: Data,
        stream: LogStream,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) {
        let key = SanitizerKey(serviceID: serviceID, runID: runID, stream: stream)
        var decoder = decoders[key] ?? UTF8StreamDecoder()
        let text = decoder.append(data)
        decoders[key] = decoder
        guard !text.isEmpty else { return }
        appendSanitized(text, stream: stream, key: key, workspaceID: workspaceID, serviceID: serviceID)
    }

    /// Flushes a raw pipe decoder on EOF so a truncated scalar is visibly represented.
    public func finishStream(
        stream: LogStream,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) {
        let key = SanitizerKey(serviceID: serviceID, runID: runID, stream: stream)
        guard var decoder = decoders.removeValue(forKey: key) else { return }
        let text = decoder.finish()
        if !text.isEmpty {
            appendSanitized(text, stream: stream, key: key, workspaceID: workspaceID, serviceID: serviceID)
        }
        sanitizers[key] = nil
    }

    /// Loads persisted history only on the first request for a service after launch.
    @discardableResult
    public func loadRecent(workspaceID: UUID, serviceID: UUID, limit: Int = LogStore.defaultMaximumEntries) -> [LogEntry] {
        if !loadedHistory.contains(serviceID) {
            do {
                let writer = try writer(workspaceID: workspaceID, serviceID: serviceID)
                let records = try writer.readAllRecords { message in
                    self.emitWarning(serviceID: serviceID, kind: .malformedRecord, message: message)
                }
                entriesByService[serviceID] = []
                for record in records { appendToMemory(record, serviceID: serviceID) }
                loadedHistory.insert(serviceID)
            } catch {
                emitWarning(serviceID: serviceID, kind: .read, message: error.localizedDescription)
            }
        }
        return Array((entriesByService[serviceID] ?? []).suffix(max(0, limit)))
    }

    public func entries(serviceID: UUID) -> [LogEntry] {
        entriesByService[serviceID] ?? []
    }

    public func clearView(serviceID: UUID) {
        entriesByService[serviceID] = []
    }

    /// Drops all in-memory handles after a service log directory has been moved to
    /// Trash. The next append or load recreates a fresh UUID-derived directory.
    public func forgetHistory(serviceID: UUID) {
        entriesByService[serviceID] = []
        writers[serviceID] = nil
        locations[serviceID] = nil
        decoders = decoders.filter { $0.key.serviceID != serviceID }
        sanitizers = sanitizers.filter { $0.key.serviceID != serviceID }
        loadedHistory.remove(serviceID)
    }

    /// Removes only the UUID-derived service directory that this store has prepared or
    /// opened. Task 10 replaces this with a Trash-coordinated destructive workflow.
    public func deleteHistory(serviceID: UUID) {
        guard let location = locations[serviceID] else { return }
        do {
            let writer = try writer(workspaceID: location.workspaceID, serviceID: serviceID)
            try writer.removeHistory()
            entriesByService[serviceID] = []
            writers[serviceID] = nil
            locations[serviceID] = nil
            decoders = decoders.filter { $0.key.serviceID != serviceID }
            sanitizers = sanitizers.filter { $0.key.serviceID != serviceID }
            loadedHistory.remove(serviceID)
        } catch {
            emitWarning(serviceID: serviceID, kind: .delete, message: error.localizedDescription)
        }
    }

    public func warnings() -> [LogStoreWarning] {
        storedWarnings
    }

    private func writer(workspaceID: UUID, serviceID: UUID) throws -> RotatingLogWriter {
        let expectedDirectory = logDirectory(workspaceID: workspaceID, serviceID: serviceID)
        if let location = locations[serviceID] {
            guard location.workspaceID == workspaceID, location.directory == expectedDirectory else {
                throw RotatingLogWriterError.unsafeLogDirectory
            }
        }
        if let existing = writers[serviceID] { return existing }

        try ensureLogRootIsSafe()
        try ensureWorkspaceDirectoryIsSafe(workspaceID: workspaceID)
        let writer = try RotatingLogWriter(
            directory: expectedDirectory,
            maximumFileSizeBytes: maximumFileSizeBytes,
            fileCount: fileCount,
            fileManager: fileManager
        )
        try writer.prepare()
        locations[serviceID] = ServiceLocation(workspaceID: workspaceID, serviceID: serviceID, directory: expectedDirectory)
        writers[serviceID] = writer
        return writer
    }

    private func logDirectory(workspaceID: UUID, serviceID: UUID) -> URL {
        paths.logsRootURL
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(serviceID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    private func ensureLogRootIsSafe() throws {
        let root = paths.logsRootURL.standardizedFileURL
        if fileManager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RotatingLogWriterError.unsafeLogDirectory
            }
            return
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func ensureWorkspaceDirectoryIsSafe(workspaceID: UUID) throws {
        let workspaceDirectory = paths.logsRootURL
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
        if fileManager.fileExists(atPath: workspaceDirectory.path) {
            let values = try workspaceDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RotatingLogWriterError.unsafeLogDirectory
            }
            return
        }
        try fileManager.createDirectory(at: workspaceDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspaceDirectory.path)
    }

    private func appendToMemory(_ entry: LogEntry, serviceID: UUID) {
        var entries = entriesByService[serviceID] ?? []
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        entriesByService[serviceID] = entries
    }

    private func appendSanitized(
        _ text: String,
        stream: LogStream,
        key: SanitizerKey,
        workspaceID: UUID,
        serviceID: UUID
    ) {
        var sanitizer = sanitizers[key] ?? LogSanitizer()
        let sanitizedText = sanitizer.append(text)
        sanitizers[key] = sanitizer
        guard !sanitizedText.isEmpty else { return }
        let entry = LogEntry(stream: stream, text: sanitizedText)
        do {
            let writer = try writer(workspaceID: workspaceID, serviceID: serviceID)
            try writer.append(entry)
        } catch {
            emitWarning(serviceID: serviceID, kind: .write, message: error.localizedDescription)
        }
        appendToMemory(entry, serviceID: serviceID)
    }

    private func emitWarning(serviceID: UUID, kind: LogStoreWarning.Kind, message: String) {
        let key = "\(serviceID.uuidString)-\(kind)-\(message)"
        guard warningKeys.insert(key).inserted else { return }
        storedWarnings.append(LogStoreWarning(serviceID: serviceID, kind: kind, message: message))
    }
}
