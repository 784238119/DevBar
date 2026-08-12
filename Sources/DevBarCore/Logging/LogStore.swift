import Foundation

public struct LogStoreWarning: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case initialization
        case read
        case write
        case malformedRecord
        case delete
        case cleanup
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
    /// Supports the configurable log viewer limit: memory retains at most the most
    /// recent 10,000 output lines while rotating files remain the full history source.
    public static let defaultMaximumEntries = 10_000

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

    private var logsRootURL: URL
    private let defaultLogsRootURL: URL
    private let maximumEntries: Int
    private var maximumFileSizeBytes: Int
    private var fileCount: Int
    private var retentionDays: Int
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var calendar: Calendar
    private var lastCleanupAt: Date?
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
        retentionDays: Int = PreferencesConfig.defaultLogRetentionDays,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        logsRootURL = paths.logsRootURL
        defaultLogsRootURL = paths.logsRootURL
        self.maximumEntries = max(1, maximumEntries)
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.fileCount = fileCount
        self.retentionDays = retentionDays
        self.fileManager = fileManager
        self.now = now
        self.calendar = calendar
    }

    /// Applies the saved rotation policy before a service starts. Writers do not hold
    /// open file descriptors, so dropping the cache safely applies the new policy to
    /// the next append without interrupting existing processes.
    public func configure(logDirectory: String, logFileSizeMiB: Int, fileCount: Int, retentionDays: Int) throws {
        guard (1...100).contains(logFileSizeMiB), (1...10).contains(fileCount),
              PreferencesConfig.logRetentionDaysRange.contains(retentionDays) else {
            throw RotatingLogWriterError.invalidConfiguration
        }
        let configuredRoot = URL(fileURLWithPath: logDirectory, isDirectory: true).standardizedFileURL
        guard configuredRoot.path == logDirectory, configuredRoot.path != "/" else {
            throw RotatingLogWriterError.unsafeLogDirectory
        }
        let requestedRoot = logDirectory == PreferencesConfig.defaultLogDirectory
            ? defaultLogsRootURL
            : configuredRoot
        let maximumFileSizeBytes = logFileSizeMiB * 1_024 * 1_024
        guard self.maximumFileSizeBytes != maximumFileSizeBytes
                || self.fileCount != fileCount
                || self.retentionDays != retentionDays
                || logsRootURL != requestedRoot else {
            try cleanupExpiredLogsIfNeeded(force: false)
            return
        }
        logsRootURL = requestedRoot
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.fileCount = fileCount
        self.retentionDays = retentionDays
        lastCleanupAt = nil
        writers.removeAll()
        locations.removeAll()
        loadedHistory.removeAll()
        try cleanupExpiredLogsIfNeeded(force: true)
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
                let records = try readRecentRecords(workspaceID: workspaceID, serviceID: serviceID, limit: limit)
                replaceMemory(with: records, serviceID: serviceID)
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
            let serviceDirectory = serviceDirectory(workspaceID: location.workspaceID, serviceID: serviceID)
            guard serviceDirectory.path.hasPrefix(logsRootURL.path + "/") else {
                throw RotatingLogWriterError.unsafeLogDirectory
            }
            if fileManager.fileExists(atPath: serviceDirectory.path) {
                let values = try serviceDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw RotatingLogWriterError.unsafeLogDirectory
                }
                try fileManager.removeItem(at: serviceDirectory)
            }
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
        try cleanupExpiredLogsIfNeeded(force: false)
        let expectedDirectory = logDirectory(workspaceID: workspaceID, serviceID: serviceID, date: now())
        if let location = locations[serviceID] {
            guard location.workspaceID == workspaceID else {
                throw RotatingLogWriterError.unsafeLogDirectory
            }
            if location.directory != expectedDirectory {
                writers[serviceID] = nil
                locations[serviceID] = nil
                loadedHistory.remove(serviceID)
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

    private func serviceDirectory(workspaceID: UUID, serviceID: UUID) -> URL {
        logsRootURL
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(serviceID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    private func logDirectory(workspaceID: UUID, serviceID: UUID, date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return serviceDirectory(workspaceID: workspaceID, serviceID: serviceID)
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
            .standardizedFileURL
    }

    private func ensureLogRootIsSafe() throws {
        let root = logsRootURL.standardizedFileURL
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
        let workspaceDirectory = logsRootURL
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

    private func readRecentRecords(workspaceID: UUID, serviceID: UUID, limit: Int) throws -> [LogEntry] {
        guard limit > 0 else { return [] }
        let directories = try historyDirectories(workspaceID: workspaceID, serviceID: serviceID)
        var newestFirst: [LogEntry] = []
        for directory in directories.reversed() {
            let reader = try RotatingLogWriter(
                directory: directory,
                maximumFileSizeBytes: maximumFileSizeBytes,
                fileCount: fileCount,
                fileManager: fileManager
            )
            let remaining = limit - newestFirst.count
            let records = try reader.readRecentRecords(limit: remaining) { message in
                self.emitWarning(serviceID: serviceID, kind: .malformedRecord, message: message)
            }
            newestFirst.insert(contentsOf: records, at: 0)
            if newestFirst.count >= limit { break }
        }
        return Array(newestFirst.suffix(limit))
    }

    /// Returns the legacy service directory first, followed by dated directories in
    /// chronological order. This keeps logs written before date partitioning readable.
    private func historyDirectories(workspaceID: UUID, serviceID: UUID) throws -> [URL] {
        let serviceRoot = serviceDirectory(workspaceID: workspaceID, serviceID: serviceID)
        guard fileManager.fileExists(atPath: serviceRoot.path) else { return [] }
        let values = try serviceRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RotatingLogWriterError.unsafeLogDirectory
        }
        var directories: [URL] = []
        if fileManager.fileExists(atPath: serviceRoot.appendingPathComponent("current.log").path) {
            directories.append(serviceRoot)
        }
        for year in try numericDirectories(in: serviceRoot, digits: 4) {
            for month in try numericDirectories(in: year, digits: 2) {
                directories.append(contentsOf: try numericDirectories(in: month, digits: 2))
            }
        }
        return directories
    }

    private func numericDirectories(in parent: URL, digits: Int) throws -> [URL] {
        guard fileManager.fileExists(atPath: parent.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let name = url.lastPathComponent
            guard name.count == digits, name.allSatisfy(\.isNumber) else { return false }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw RotatingLogWriterError.unsafeLogDirectory }
            return values.isDirectory == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func cleanupExpiredLogsIfNeeded(force: Bool) throws {
        let currentDate = now()
        if !force, let lastCleanupAt, currentDate.timeIntervalSince(lastCleanupAt) < 60 * 60 { return }
        guard fileManager.fileExists(atPath: logsRootURL.path) else {
            lastCleanupAt = currentDate
            return
        }
        let today = calendar.startOfDay(for: currentDate)
        guard let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) else { return }

        for workspace in try uuidDirectories(in: logsRootURL) {
            for service in try uuidDirectories(in: workspace) {
                for year in try numericDirectories(in: service, digits: 4) {
                    for month in try numericDirectories(in: year, digits: 2) {
                        for day in try numericDirectories(in: month, digits: 2) {
                            let parts = DateComponents(
                                calendar: calendar,
                                year: Int(year.lastPathComponent),
                                month: Int(month.lastPathComponent),
                                day: Int(day.lastPathComponent)
                            )
                            guard let directoryDate = calendar.date(from: parts), directoryDate < cutoff else { continue }
                            try fileManager.removeItem(at: day)
                        }
                        try removeDirectoryIfEmpty(month)
                    }
                    try removeDirectoryIfEmpty(year)
                }
            }
        }
        lastCleanupAt = currentDate
    }

    private func uuidDirectories(in parent: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard UUID(uuidString: url.lastPathComponent) != nil else { return false }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw RotatingLogWriterError.unsafeLogDirectory }
            return values.isDirectory == true
        }
    }

    private func removeDirectoryIfEmpty(_ directory: URL) throws {
        if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private func appendToMemory(_ entry: LogEntry, serviceID: UUID) {
        var entries = entriesByService[serviceID] ?? []
        entries.append(contentsOf: displayLines(from: entry))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        entriesByService[serviceID] = entries
    }

    private func replaceMemory(with records: [LogEntry], serviceID: UUID) {
        var lines: [LogEntry] = []
        lines.reserveCapacity(min(maximumEntries, records.count))
        for record in records {
            lines.append(contentsOf: displayLines(from: record))
            if lines.count > maximumEntries * 2 {
                lines = Array(lines.suffix(maximumEntries))
            }
        }
        entriesByService[serviceID] = Array(lines.suffix(maximumEntries))
    }

    /// Pipe callbacks may contain many lines. Splitting only the in-memory display
    /// makes the retention limit match `tail -n` without changing on-disk output.
    private func displayLines(from entry: LogEntry) -> [LogEntry] {
        let components = entry.text.components(separatedBy: "\n")
        return components.enumerated().compactMap { index, component in
            if index == components.count - 1, component.isEmpty, entry.text.hasSuffix("\n") {
                return nil
            }
            let suffix = index < components.count - 1 ? "\n" : ""
            return LogEntry(timestamp: entry.timestamp, stream: entry.stream, text: component + suffix)
        }
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
