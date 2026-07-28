import Darwin
import Foundation

public enum LogStream: String, Codable, CaseIterable, Sendable {
    case stdout
    case stderr
}

public struct LogEntry: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let stream: LogStream
    public let text: String

    public init(timestamp: Date = Date(), stream: LogStream, text: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }
}

public enum RotatingLogWriterError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration
    case unsafeLogDirectory
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The log rotation configuration is invalid."
        case .unsafeLogDirectory: "DevBar refused an unsafe log directory."
        case let .fileSystem(message): "DevBar could not write a service log: \(message)"
        }
    }
}

/// Persists decoded command output after `LogSanitizer` removes terminal controls.
public final class RotatingLogWriter: @unchecked Sendable {
    public let directory: URL
    private let maximumFileSizeBytes: Int
    private let fileCount: Int
    private let fileManager: FileManager
    private let dateFormatter: ISO8601DateFormatter

    public init(
        directory: URL,
        maximumFileSizeBytes: Int,
        fileCount: Int,
        fileManager: FileManager = .default
    ) throws {
        guard maximumFileSizeBytes >= 64, fileCount >= 1 else {
            throw RotatingLogWriterError.invalidConfiguration
        }
        self.directory = directory.standardizedFileURL
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.fileCount = fileCount
        self.fileManager = fileManager
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func prepare() throws {
        try ensureSafeDirectory(directory)
    }

    public func append(_ entry: LogEntry) throws {
        try prepare()
        for row in encodedRows(for: entry) {
            try rotateIfNeeded(for: row.count)
            try appendBytes(row, to: currentURL)
        }
    }

    public func readAllRecords() throws -> [LogEntry] {
        try prepare()
        var records: [LogEntry] = []
        for url in logURLsOldestFirst() where fileManager.fileExists(atPath: url.path) {
            guard try isRegularNonSymlink(url) else { throw RotatingLogWriterError.unsafeLogDirectory }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw RotatingLogWriterError.fileSystem(error.localizedDescription) }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let record = decodeRecord(String(decoding: line, as: UTF8.self)) {
                    records.append(record)
                }
            }
        }
        return records
    }

    public func readAllRecords(skippingMalformed: (String) -> Void) throws -> [LogEntry] {
        try prepare()
        var records: [LogEntry] = []
        var warned = false
        for url in logURLsOldestFirst() where fileManager.fileExists(atPath: url.path) {
            guard try isRegularNonSymlink(url) else { throw RotatingLogWriterError.unsafeLogDirectory }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw RotatingLogWriterError.fileSystem(error.localizedDescription) }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let decoded = String(decoding: line, as: UTF8.self)
                if let record = decodeRecord(decoded) {
                    records.append(record)
                } else if !warned {
                    warned = true
                    skippingMalformed("Skipped one or more malformed log records.")
                }
            }
        }
        return records
    }

    public func removeHistory() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard try isDirectoryNonSymlink(directory) else { throw RotatingLogWriterError.unsafeLogDirectory }
        do { try fileManager.removeItem(at: directory) }
        catch { throw RotatingLogWriterError.fileSystem(error.localizedDescription) }
    }

    private var currentURL: URL {
        directory.appendingPathComponent("current.log", isDirectory: false)
    }

    private func archiveURL(_ number: Int) -> URL {
        directory.appendingPathComponent("current.log.\(number)", isDirectory: false)
    }

    private func logURLsOldestFirst() -> [URL] {
        let archives = stride(from: fileCount - 1, through: 1, by: -1).map(archiveURL)
        return archives + [currentURL]
    }

    private func encodedRows(for entry: LogEntry) -> [Data] {
        let prefix = "\(dateFormatter.string(from: entry.timestamp))\t\(entry.stream.rawValue)\t"
        let escaped = escape(entry.text)
        let newline = "\n"
        let payloadBudget = maximumFileSizeBytes - Data((prefix + newline).utf8).count
        guard payloadBudget > 0 else { return [Data((prefix + newline).utf8)] }

        let chunks = splitUTF8(escaped, maximumBytes: payloadBudget)
        return chunks.map { Data((prefix + $0 + newline).utf8) }
    }

    private func splitUTF8(_ text: String, maximumBytes: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        var rows: [String] = []
        var row = ""
        var size = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let fragmentSize = Data(fragment.utf8).count
            if size > 0, size + fragmentSize > maximumBytes {
                rows.append(row)
                row = ""
                size = 0
            }
            // A UTF-8 scalar is at most four bytes and the production minimum is 1 MiB.
            // Keep the data valid even for small test thresholds.
            if fragmentSize > maximumBytes {
                continue
            }
            row += fragment
            size += fragmentSize
        }
        if !row.isEmpty || rows.isEmpty { rows.append(row) }
        return rows
    }

    private func rotateIfNeeded(for incomingByteCount: Int) throws {
        let existingSize = try fileSize(of: currentURL)
        guard existingSize > 0, existingSize + incomingByteCount > maximumFileSizeBytes else { return }

        if fileCount > 1 {
            try removeIfPresent(archiveURL(fileCount - 1))
            if fileCount > 2 {
                for index in stride(from: fileCount - 2, through: 1, by: -1) {
                    let source = archiveURL(index)
                    if fileManager.fileExists(atPath: source.path) {
                        try fileManager.moveItem(at: source, to: archiveURL(index + 1))
                    }
                }
            }
            if fileManager.fileExists(atPath: currentURL.path) {
                try fileManager.moveItem(at: currentURL, to: archiveURL(1))
            }
        } else {
            try removeIfPresent(currentURL)
        }
    }

    private func appendBytes(_ bytes: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw RotatingLogWriterError.fileSystem(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        do {
            try bytes.withUnsafeBytes { buffer in
                var written = 0
                while written < buffer.count {
                    let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw RotatingLogWriterError.fileSystem(String(cString: strerror(errno)))
                    }
                    written += result
                }
            }
        } catch let error as RotatingLogWriterError {
            throw error
        } catch {
            throw RotatingLogWriterError.fileSystem(error.localizedDescription)
        }
    }

    private func fileSize(of url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        guard try isRegularNonSymlink(url) else { throw RotatingLogWriterError.unsafeLogDirectory }
        do {
            return (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw RotatingLogWriterError.fileSystem(error.localizedDescription)
        }
    }

    private func ensureSafeDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard try isDirectoryNonSymlink(url) else { throw RotatingLogWriterError.unsafeLogDirectory }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw RotatingLogWriterError.fileSystem(error.localizedDescription)
        }
        guard try isDirectoryNonSymlink(url) else { throw RotatingLogWriterError.unsafeLogDirectory }
    }

    private func isDirectoryNonSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isRegularNonSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func decodeRecord(_ line: String) -> LogEntry? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let timestamp = dateFormatter.date(from: String(parts[0])),
              let stream = LogStream(rawValue: String(parts[1])) else { return nil }
        return LogEntry(timestamp: timestamp, stream: stream, text: unescape(String(parts[2])))
    }

    private func unescape(_ text: String) -> String {
        var output = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                output.append(character)
                continue
            }
            switch escaped {
            case "t": output.append("\t")
            case "n": output.append("\n")
            case "\\": output.append("\\")
            default:
                output.append("\\")
                output.append(escaped)
            }
        }
        return output
    }
}
