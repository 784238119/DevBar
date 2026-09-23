import Darwin
import Foundation
import Security

protocol MCPTokenProviding {
    var configurationPath: String { get }
    func load() throws -> String?
    func generate() throws -> String
    func saveToCodexConfiguration(token: String, endpoint: String) throws
    func deleteLegacyKeychainToken() throws
}

struct MCPTokenStore: MCPTokenProviding {
    private static let legacyService = "com.calo.DevBar.MCP"
    private static let legacyAccount = "localhost"

    private let configurationURL: URL
    private let legacyKeychainCleanup: () throws -> Void

    init(
        configurationFileURL: URL? = nil,
        legacyKeychainCleanup: (() throws -> Void)? = nil
    ) {
        configurationURL = (configurationFileURL ?? Self.defaultConfigurationURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.legacyKeychainCleanup = legacyKeychainCleanup ?? {
            try Self.deleteLegacyKeychainCredential()
        }
    }

    var configurationPath: String { configurationURL.path }

    func load() throws -> String? {
        try CodexMCPConfigurationFile.loadToken(from: configurationURL)
    }

    func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw MCPTokenStoreError.randomFailed }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func saveToCodexConfiguration(token: String, endpoint: String) throws {
        try CodexMCPConfigurationFile.save(
            token: token,
            endpoint: endpoint,
            to: configurationURL
        )
    }

    func deleteLegacyKeychainToken() throws {
        try legacyKeychainCleanup()
    }

    private static var defaultConfigurationURL: URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let directory = if let codexHome, !codexHome.isEmpty {
            URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return directory.appendingPathComponent("config.toml", isDirectory: false)
    }

    private static func deleteLegacyKeychainCredential() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPTokenStoreError.legacyKeychainCleanup(status)
        }
    }
}

enum MCPTokenStoreError: Error, LocalizedError {
    case randomFailed
    case configuration(String)
    case legacyKeychainCleanup(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomFailed:
            "Could not generate a secure DevBar MCP token."
        case let .configuration(message):
            "Could not configure DevBar in Codex config.toml: \(message)"
        case let .legacyKeychainCleanup(status):
            "Codex was configured, but the previous DevBar Keychain token could not be removed (\(status))."
        }
    }
}

enum CodexMCPConfigurationFile {
    private static let serverTable = "mcp_servers.devbar"
    private static let managedKeys: Set<String> = [
        "url", "http_headers", "http_headers_helper", "bearer_token_env_var", "enabled"
    ]

    static func loadToken(from url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MCPTokenStoreError.configuration("Unable to read config.toml: \(error.localizedDescription)")
        }
        let lines = lines(from: content)
        guard let range = try serverTableRange(in: lines) else { return nil }
        let headers = try headerMap(in: lines, range: range)
        guard let authorization = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })?.value,
              authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    static func save(token: String, endpoint: String, to url: URL) throws {
        guard !token.isEmpty else {
            throw MCPTokenStoreError.configuration("The Authorization token is empty.")
        }
        let fileManager = FileManager.default
        let content: String
        if fileManager.fileExists(atPath: url.path) {
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw MCPTokenStoreError.configuration("Unable to read config.toml: \(error.localizedDescription)")
            }
        } else {
            content = ""
        }
        let updated = try updating(content, token: token, endpoint: endpoint)
        try writeAtomically(updated, to: url)
    }

    static func updating(_ content: String, token: String, endpoint: String) throws -> String {
        var fileLines = lines(from: content)
        let existingTableRange = try serverTableRange(in: fileLines)

        var headers: [String: String] = [:]
        if let range = existingTableRange {
            headers = try headerMap(in: fileLines, range: range)

            var retained: [String] = []
            var lineIndex = range.lowerBound
            while lineIndex < range.upperBound {
                let line = fileLines[lineIndex]
                if assignmentKey(in: line) == "http_headers" {
                    lineIndex = try httpHeadersEndIndex(startingAt: lineIndex, in: fileLines, before: range.upperBound) + 1
                    continue
                }
                if let key = assignmentKey(in: line), managedKeys.contains(key) {
                    lineIndex += 1
                    continue
                }
                retained.append(line)
                lineIndex += 1
            }
            var block = retained
            while block.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                block.removeLast()
            }
            block.append(contentsOf: managedLines(headers: headers, token: token, endpoint: endpoint, includeTimeout: !hasAssignment("tool_timeout_sec", in: retained)))
            fileLines.replaceSubrange(range, with: block)
        } else {
            if let parent = fileLines.indices.first(where: { tableName(in: fileLines[$0]) == "mcp_servers" }),
               let end = nextTableIndex(after: parent, in: fileLines),
               fileLines[parent..<end].contains(where: { assignmentKey(in: $0) == "devbar" }) {
                throw MCPTokenStoreError.configuration("The DevBar MCP entry is inline inside [mcp_servers]; edit it manually before using one-click setup.")
            }
            if fileLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                fileLines.append("")
            }
            fileLines.append("[mcp_servers.devbar]")
            fileLines.append(contentsOf: managedLines(headers: headers, token: token, endpoint: endpoint, includeTimeout: true))
        }
        return fileLines.joined(separator: "\n") + "\n"
    }

    private static func serverTableRange(in lines: [String]) throws -> Range<Int>? {
        let starts = lines.indices.filter { tableName(in: lines[$0]) == serverTable }
        guard starts.count <= 1 else {
            throw MCPTokenStoreError.configuration("The DevBar MCP table appears more than once.")
        }
        if lines.contains(where: { arrayTableName(in: $0) == serverTable }) {
            throw MCPTokenStoreError.configuration("The DevBar MCP entry uses an unsupported array-table form.")
        }
        guard let start = starts.first else { return nil }
        return start..<(nextTableIndex(after: start, in: lines) ?? lines.endIndex)
    }

    private static func managedLines(
        headers: [String: String],
        token: String,
        endpoint: String,
        includeTimeout: Bool
    ) -> [String] {
        var merged = headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        merged["Authorization"] = "Bearer \(token)"
        let headerEntries = merged.keys.sorted().map { "\(tomlString($0)) = \(tomlString(merged[$0] ?? ""))" }
        var lines = [
            "url = \(tomlString(endpoint))",
            "http_headers = { \(headerEntries.joined(separator: ", ")) }"
        ]
        if includeTimeout { lines.append("tool_timeout_sec = 120") }
        lines.append("enabled = true")
        return lines
    }

    private static func headerMap(in lines: [String], range: Range<Int>) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = range.lowerBound
        while index < range.upperBound {
            guard assignmentKey(in: lines[index]) == "http_headers" else {
                index += 1
                continue
            }
            let end = try httpHeadersEndIndex(startingAt: index, in: lines, before: range.upperBound)
            var expression = assignmentValue(in: lines[index])
            if end > index {
                expression += "\n" + lines[(index + 1)...end].joined(separator: "\n")
            }
            for (key, value) in try parseInlineStringMap(expression) {
                guard result[key] == nil else {
                    throw MCPTokenStoreError.configuration("The existing http_headers table contains duplicate keys.")
                }
                result[key] = value
            }
            index = end + 1
        }
        return result
    }

    private static func httpHeadersEndIndex(startingAt start: Int, in lines: [String], before upperBound: Int) throws -> Int {
        var expression = assignmentValue(in: lines[start])
        var end = start
        while !isCompleteInlineTable(expression), end + 1 < upperBound {
            end += 1
            expression += "\n" + lines[end]
        }
        guard isCompleteInlineTable(expression) else {
            throw MCPTokenStoreError.configuration("The existing http_headers value is not a complete inline table.")
        }
        return end
    }

    private static func parseInlineStringMap(_ source: String) throws -> [String: String] {
        let value = uncommented(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "{", value.last == "}" else {
            throw MCPTokenStoreError.configuration("The existing http_headers value must be an inline table.")
        }
        let end = value.index(before: value.endIndex)
        var cursor = value.index(after: value.startIndex)
        var entries: [String: String] = [:]

        while true {
            skipWhitespace(in: value, cursor: &cursor, before: end)
            if cursor == end { break }
            let key = try parseKey(in: value, cursor: &cursor, before: end)
            skipWhitespace(in: value, cursor: &cursor, before: end)
            guard cursor < end, value[cursor] == "=" else {
                throw MCPTokenStoreError.configuration("Could not parse an existing http_headers entry.")
            }
            cursor = value.index(after: cursor)
            skipWhitespace(in: value, cursor: &cursor, before: end)
            let headerValue = try parseQuotedString(in: value, cursor: &cursor, before: end)
            guard entries[key] == nil else {
                throw MCPTokenStoreError.configuration("The existing http_headers table contains duplicate keys.")
            }
            entries[key] = headerValue
            skipWhitespace(in: value, cursor: &cursor, before: end)
            if cursor == end { break }
            guard value[cursor] == "," else {
                throw MCPTokenStoreError.configuration("Could not parse an existing http_headers table.")
            }
            cursor = value.index(after: cursor)
        }
        return entries
    }

    private static func parseKey(in value: String, cursor: inout String.Index, before end: String.Index) throws -> String {
        guard cursor < end else { throw MCPTokenStoreError.configuration("Missing an http_headers key.") }
        if value[cursor] == "\"" || value[cursor] == "'" {
            return try parseQuotedString(in: value, cursor: &cursor, before: end)
        }
        let start = cursor
        while cursor < end, value[cursor] != "=", value[cursor] != ",", !value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
        guard start < cursor else { throw MCPTokenStoreError.configuration("Missing an http_headers key.") }
        return String(value[start..<cursor])
    }

    private static func parseQuotedString(in value: String, cursor: inout String.Index, before end: String.Index) throws -> String {
        guard cursor < end, value[cursor] == "\"" || value[cursor] == "'" else {
            throw MCPTokenStoreError.configuration("http_headers keys and values must be strings.")
        }
        let quote = value[cursor]
        let start = cursor
        cursor = value.index(after: cursor)
        var escaped = false
        while cursor < end {
            let character = value[cursor]
            if character == quote, !escaped {
                cursor = value.index(after: cursor)
                let literal = String(value[start..<cursor])
                if quote == "'" { return String(literal.dropFirst().dropLast()) }
                do {
                    return try JSONDecoder().decode(String.self, from: Data(literal.utf8))
                } catch {
                    throw MCPTokenStoreError.configuration("Could not decode a string in http_headers.")
                }
            }
            if quote == "\"", character == "\\", !escaped { escaped = true }
            else { escaped = false }
            cursor = value.index(after: cursor)
        }
        throw MCPTokenStoreError.configuration("Unterminated string in http_headers.")
    }

    private static func isCompleteInlineTable(_ value: String) -> Bool {
        let value = uncommented(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.first == "{" && value.last == "}"
    }

    private static func hasAssignment(_ key: String, in lines: [String]) -> Bool {
        lines.contains { assignmentKey(in: $0) == key }
    }

    private static func assignmentKey(in line: String) -> String? {
        let code = uncommented(line)
        guard let equals = code.firstIndex(of: "=") else { return nil }
        var key = code[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 2, (key.first == "\"" && key.last == "\"") || (key.first == "'" && key.last == "'") {
            key = String(key.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : key
    }

    private static func assignmentValue(in line: String) -> String {
        let code = uncommented(line)
        guard let equals = code.firstIndex(of: "=") else { return "" }
        return String(code[code.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableName(in line: String) -> String? {
        let code = uncommented(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("["), !code.hasPrefix("[["),
              let closing = code.firstIndex(of: "]") else { return nil }
        let trailing = code[code.index(after: closing)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty else { return nil }
        return String(code[code.index(after: code.startIndex)..<closing])
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func arrayTableName(in line: String) -> String? {
        let code = uncommented(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("[["), let closing = code.range(of: "]]" ) else { return nil }
        return String(code[code.index(code.startIndex, offsetBy: 2)..<closing.lowerBound])
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nextTableIndex(after index: Int, in lines: [String]) -> Int? {
        guard index + 1 < lines.endIndex else { return nil }
        return lines[(index + 1)...].firstIndex { tableName(in: $0) != nil || arrayTableName(in: $0) != nil }
    }

    private static func lines(from content: String) -> [String] {
        var result = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { result.removeLast() }
        if content.isEmpty { return [] }
        return result
    }

    private static func skipWhitespace(in value: String, cursor: inout String.Index, before end: String.Index) {
        while cursor < end, value[cursor].isWhitespace { cursor = value.index(after: cursor) }
    }

    private static func uncommented(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if character == "#", quote == nil { break }
            result.append(character)
            if let currentQuote = quote {
                if currentQuote == "\"", character == "\\", !escaped { escaped = true }
                else {
                    if character == currentQuote, !escaped { quote = nil }
                    escaped = false
                }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return result
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0C: escaped += "\\f"
            case 0x0D: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x00...0x1F, 0x7F: escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }

    private static func writeAtomically(_ content: String, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MCPTokenStoreError.configuration("Unable to create the Codex configuration directory: \(error.localizedDescription)")
        }

        let temporaryURL = directory.appendingPathComponent(".config.toml.\(UUID().uuidString).tmp", isDirectory: false)
        var descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw MCPTokenStoreError.configuration("Unable to create a private temporary config file: \(String(cString: strerror(errno)))")
        }
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if fileManager.fileExists(atPath: temporaryURL.path) { try? fileManager.removeItem(at: temporaryURL) }
        }

        let data = Data(content.utf8)
        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw MCPTokenStoreError.configuration("Unable to write Codex config.toml: \(String(cString: strerror(errno)))")
                    }
                    guard written > 0 else {
                        throw MCPTokenStoreError.configuration("Unable to finish writing Codex config.toml.")
                    }
                    offset += written
                }
            }
        } catch {
            throw error
        }
        guard fsync(descriptor) == 0 else {
            throw MCPTokenStoreError.configuration("Unable to synchronize Codex config.toml: \(String(cString: strerror(errno)))")
        }
        let closeStatus = close(descriptor)
        descriptor = -1
        guard closeStatus == 0 else {
            throw MCPTokenStoreError.configuration("Unable to close the temporary Codex config file: \(String(cString: strerror(errno)))")
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw MCPTokenStoreError.configuration("Unable to replace Codex config.toml: \(String(cString: strerror(errno)))")
        }
    }
}
