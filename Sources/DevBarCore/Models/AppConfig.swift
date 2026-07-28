import Foundation

public enum AppConfigDecodingError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "DevBar cannot read configuration schema version \(version). Update DevBar before opening this configuration."
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var workspaces: [WorkspaceConfig]
    public var preferences: PreferencesConfig

    public init(
        schemaVersion: Int = AppConfig.supportedSchemaVersion,
        workspaces: [WorkspaceConfig],
        preferences: PreferencesConfig
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.preferences = preferences
    }

    public static let empty = AppConfig(workspaces: [], preferences: .default)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw AppConfigDecodingError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        workspaces = try container.decode([WorkspaceConfig].self, forKey: .workspaces)
        preferences = try container.decode(PreferencesConfig.self, forKey: .preferences)
    }
}

public struct WorkspaceConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rootDirectory: String
    public var iconSymbol: String
    public var tintHex: String
    public var environment: [EnvironmentEntry]
    public var services: [ServiceConfig]

    public init(
        id: UUID = UUID(),
        name: String,
        rootDirectory: String,
        iconSymbol: String,
        tintHex: String,
        environment: [EnvironmentEntry],
        services: [ServiceConfig]
    ) {
        self.id = id
        self.name = name
        self.rootDirectory = rootDirectory
        self.iconSymbol = iconSymbol
        self.tintHex = tintHex
        self.environment = environment
        self.services = services
    }
}

public struct ServiceConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var workingDirectory: WorkingDirectory
    public var command: String
    public var includeInStartAll: Bool
    public var environment: [EnvironmentEntry]
    public var healthCheck: HealthCheckConfig

    public init(
        id: UUID = UUID(),
        name: String,
        workingDirectory: WorkingDirectory,
        command: String,
        includeInStartAll: Bool = true,
        environment: [EnvironmentEntry] = [],
        healthCheck: HealthCheckConfig = .none
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.command = command
        self.includeInStartAll = includeInStartAll
        self.environment = environment
        self.healthCheck = healthCheck
    }
}

public enum WorkingDirectory: Codable, Equatable, Sendable {
    case relative(String)
    case absolute(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    private enum Kind: String, Codable {
        case relative
        case absolute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .relative: self = .relative(path)
        case .absolute: self = .absolute(path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .relative(path):
            try container.encode(Kind.relative, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .absolute(path):
            try container.encode(Kind.absolute, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

public struct EnvironmentEntry: Codable, Equatable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public enum HealthCheckConfig: Codable, Equatable, Sendable {
    case none
    case http(URL)
    case tcp(host: String, port: Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case host
        case port
    }

    private enum Kind: String, Codable {
        case none
        case http
        case tcp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .http:
            self = .http(try container.decode(URL.self, forKey: .url))
        case .tcp:
            self = .tcp(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(Int.self, forKey: .port)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case let .http(url):
            try container.encode(Kind.http, forKey: .kind)
            try container.encode(url, forKey: .url)
        case let .tcp(host, port):
            try container.encode(Kind.tcp, forKey: .kind)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        }
    }
}

public struct PreferencesConfig: Codable, Equatable, Sendable {
    public var shellPath: String
    public var logFileSizeMiB: Int
    public var logFileCount: Int
    public var sigintGraceSeconds: Int
    public var sigtermGraceSeconds: Int

    public init(
        shellPath: String,
        logFileSizeMiB: Int,
        logFileCount: Int,
        sigintGraceSeconds: Int,
        sigtermGraceSeconds: Int
    ) {
        self.shellPath = shellPath
        self.logFileSizeMiB = logFileSizeMiB
        self.logFileCount = logFileCount
        self.sigintGraceSeconds = sigintGraceSeconds
        self.sigtermGraceSeconds = sigtermGraceSeconds
    }

    public static let `default` = PreferencesConfig(
        shellPath: "",
        logFileSizeMiB: 5,
        logFileCount: 3,
        sigintGraceSeconds: 8,
        sigtermGraceSeconds: 3
    )
}
