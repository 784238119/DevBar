import Foundation

/// The one-line JSON request that gives a Runner ownership of one foreground shell.
public struct RunnerLaunchRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let zshPath: String
    public let command: String
    public let workingDirectory: String
    public let environment: [String: String]
    public let sigintGraceSeconds: Int
    public let sigtermGraceSeconds: Int

    public init(
        runID: UUID,
        zshPath: String,
        command: String,
        workingDirectory: String,
        environment: [String: String],
        sigintGraceSeconds: Int,
        sigtermGraceSeconds: Int
    ) {
        self.runID = runID
        self.zshPath = zshPath
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.sigintGraceSeconds = sigintGraceSeconds
        self.sigtermGraceSeconds = sigtermGraceSeconds
    }
}

public enum RunnerCommand: Codable, Equatable, Sendable {
    case stop(runID: UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case runID
    }

    private enum Kind: String, Codable {
        case stop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stop:
            self = .stop(runID: try container.decode(UUID.self, forKey: .runID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stop(runID):
            try container.encode(Kind.stop, forKey: .kind)
            try container.encode(runID, forKey: .runID)
        }
    }
}

public enum RunnerEvent: Codable, Equatable, Sendable {
    case started(runID: UUID, pid: Int32, pgid: Int32)
    case stopPhase(runID: UUID, signal: Int32)
    case exited(runID: UUID, code: Int32?, signal: Int32?)
    case error(runID: UUID, message: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case runID
        case pid
        case pgid
        case signal
        case code
        case message
    }

    private enum Kind: String, Codable {
        case started
        case stopPhase
        case exited
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(UUID.self, forKey: .runID)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .started:
            self = .started(
                runID: runID,
                pid: try container.decode(Int32.self, forKey: .pid),
                pgid: try container.decode(Int32.self, forKey: .pgid)
            )
        case .stopPhase:
            self = .stopPhase(
                runID: runID,
                signal: try container.decode(Int32.self, forKey: .signal)
            )
        case .exited:
            self = .exited(
                runID: runID,
                code: try container.decodeIfPresent(Int32.self, forKey: .code),
                signal: try container.decodeIfPresent(Int32.self, forKey: .signal)
            )
        case .error:
            self = .error(runID: runID, message: try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .started(runID, pid, pgid):
            try container.encode(Kind.started, forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(pid, forKey: .pid)
            try container.encode(pgid, forKey: .pgid)
        case let .stopPhase(runID, signal):
            try container.encode(Kind.stopPhase, forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(signal, forKey: .signal)
        case let .exited(runID, code, signal):
            try container.encode(Kind.exited, forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encodeIfPresent(code, forKey: .code)
            try container.encodeIfPresent(signal, forKey: .signal)
        case let .error(runID, message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(message, forKey: .message)
        }
    }
}

public enum RunnerCodecError: Error, Equatable, Sendable, LocalizedError {
    case emptyLine
    case embeddedNewline

    public var errorDescription: String? {
        switch self {
        case .emptyLine:
            "Runner control messages must contain one JSON object."
        case .embeddedNewline:
            "Runner control messages must contain exactly one newline terminator."
        }
    }
}

/// Encodes only control-plane data. Service stdout and stderr never pass through this codec.
public enum RunnerCodec {
    public static func encodeLine<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        guard !data.isEmpty else { throw RunnerCodecError.emptyLine }
        guard !data.contains(0x0A), !data.contains(0x0D) else {
            throw RunnerCodecError.embeddedNewline
        }
        data.append(0x0A)
        return data
    }

    public static func decodeLine<Value: Decodable>(_ line: Data, as type: Value.Type) throws -> Value {
        var json = line
        if json.last == 0x0A { json.removeLast() }
        if json.last == 0x0D { json.removeLast() }
        guard !json.isEmpty else { throw RunnerCodecError.emptyLine }
        guard !json.contains(0x0A), !json.contains(0x0D) else {
            throw RunnerCodecError.embeddedNewline
        }
        return try JSONDecoder().decode(type, from: json)
    }
}
