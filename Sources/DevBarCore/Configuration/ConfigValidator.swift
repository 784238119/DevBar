import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Code: String, Sendable {
        case emptyWorkspaceName
        case invalidRootDirectory
        case invalidWorkingDirectory
        case invalidIconSymbol
        case invalidTintHex
        case emptyServiceName
        case emptyCommand
        case invalidEnvironmentKey
        case duplicateEnvironmentKey
        case invalidHTTPURL
        case invalidTCPPort
        case invalidZshPath
        case invalidPreferenceRange
    }

    public let path: String
    public let code: Code
    public let message: String

    public init(path: String, code: Code, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
}

public struct ConfigValidator {
    public static let allowedIconSymbols: Set<String> = [
        "terminal.fill",
        "server.rack",
        "hammer.fill",
        "wrench.and.screwdriver.fill",
        "shippingbox.fill",
        "cube.fill"
    ]

    public static let allowedTintHexes: Set<String> = [
        "#FF7A59",
        "#FF5C8A",
        "#A78BFA",
        "#F59E0B",
        "#34C759",
        "#0EA5E9"
    ]

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validate(_ config: AppConfig) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        validatePreferences(config.preferences, issues: &issues)

        for (workspaceIndex, workspace) in config.workspaces.enumerated() {
            let workspacePath = "workspaces[\(workspaceIndex)]"
            validateWorkspace(workspace, at: workspacePath, issues: &issues)
        }

        return issues
    }

    private func validatePreferences(_ preferences: PreferencesConfig, issues: inout [ValidationIssue]) {
        if !preferences.shellPath.isEmpty, !isExecutableRegularFile(at: preferences.shellPath) {
            issues.append(.init(
                path: "preferences.shellPath",
                code: .invalidZshPath,
                message: "The selected zsh path must be an executable file."
            ))
        }
        validateRange(preferences.logFileSizeMiB, range: 1...100, path: "preferences.logFileSizeMiB", label: "Log file size", issues: &issues)
        validateRange(preferences.logFileCount, range: 1...10, path: "preferences.logFileCount", label: "Log file count", issues: &issues)
        validateRange(preferences.sigintGraceSeconds, range: 1...60, path: "preferences.sigintGraceSeconds", label: "SIGINT grace period", issues: &issues)
        validateRange(preferences.sigtermGraceSeconds, range: 1...30, path: "preferences.sigtermGraceSeconds", label: "SIGTERM grace period", issues: &issues)
    }

    private func validateWorkspace(_ workspace: WorkspaceConfig, at path: String, issues: inout [ValidationIssue]) {
        if workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).name", code: .emptyWorkspaceName, message: "Workspace name is required."))
        }
        if !isStandardAbsoluteDirectory(workspace.rootDirectory) {
            issues.append(.init(path: "\(path).rootDirectory", code: .invalidRootDirectory, message: "Workspace root must be an existing standardized absolute directory."))
        }
        if !Self.allowedIconSymbols.contains(workspace.iconSymbol) {
            issues.append(.init(path: "\(path).iconSymbol", code: .invalidIconSymbol, message: "Choose an icon from DevBar's approved SF Symbols."))
        }
        if !Self.allowedTintHexes.contains(workspace.tintHex.uppercased()) {
            issues.append(.init(path: "\(path).tintHex", code: .invalidTintHex, message: "Choose one of DevBar's preset theme colors."))
        }

        validateEnvironment(workspace.environment, at: "\(path).environment", issues: &issues)

        for (serviceIndex, service) in workspace.services.enumerated() {
            validateService(service, workspaceRoot: workspace.rootDirectory, at: "\(path).services[\(serviceIndex)]", issues: &issues)
        }
    }

    private func validateService(_ service: ServiceConfig, workspaceRoot: String, at path: String, issues: inout [ValidationIssue]) {
        if service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).name", code: .emptyServiceName, message: "Service name is required."))
        }
        if !isValidWorkingDirectory(service.workingDirectory, workspaceRoot: workspaceRoot) {
            issues.append(.init(path: "\(path).workingDirectory", code: .invalidWorkingDirectory, message: "Service directory must resolve to an existing directory inside the workspace or be an existing absolute directory."))
        }
        if service.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "\(path).command", code: .emptyCommand, message: "Service command is required."))
        }
        validateEnvironment(service.environment, at: "\(path).environment", issues: &issues)
        validateHealthCheck(service.healthCheck, at: "\(path).healthCheck", issues: &issues)
    }

    private func validateEnvironment(_ entries: [EnvironmentEntry], at path: String, issues: inout [ValidationIssue]) {
        var seenValidKeys = Set<String>()
        for (index, entry) in entries.enumerated() {
            let keyPath = "\(path)[\(index)].key"
            guard isValidEnvironmentKey(entry.key) else {
                issues.append(.init(path: keyPath, code: .invalidEnvironmentKey, message: "Environment names must match [A-Za-z_][A-Za-z0-9_]*."))
                continue
            }
            if !seenValidKeys.insert(entry.key).inserted {
                issues.append(.init(path: keyPath, code: .duplicateEnvironmentKey, message: "Environment variable names must be unique within this scope."))
            }
        }
    }

    private func validateHealthCheck(_ healthCheck: HealthCheckConfig, at path: String, issues: inout [ValidationIssue]) {
        switch healthCheck {
        case .none:
            return
        case let .http(url):
            let scheme = url.scheme?.lowercased()
            if (scheme != "http" && scheme != "https") || url.host?.isEmpty != false {
                issues.append(.init(path: "\(path).url", code: .invalidHTTPURL, message: "HTTP health checks require an http or https URL with a host."))
            }
        case let .tcp(host, port):
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).host", code: .invalidTCPPort, message: "TCP health checks require a host and a port from 1 through 65535."))
            }
            if !(1...65_535).contains(port) {
                issues.append(.init(path: "\(path).port", code: .invalidTCPPort, message: "TCP health check port must be from 1 through 65535."))
            }
        }
    }

    private func validateRange(_ value: Int, range: ClosedRange<Int>, path: String, label: String, issues: inout [ValidationIssue]) {
        guard !range.contains(value) else { return }
        issues.append(.init(path: path, code: .invalidPreferenceRange, message: "\(label) must be between \(range.lowerBound) and \(range.upperBound)."))
    }

    private func isStandardAbsoluteDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.path == path else { return false }
        return isDirectory(at: path)
    }

    private func isValidWorkingDirectory(_ directory: WorkingDirectory, workspaceRoot: String) -> Bool {
        switch directory {
        case let .relative(path):
            guard !path.isEmpty, !URL(fileURLWithPath: path).pathComponents.contains("..") else { return false }
            let resolved = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
                .appendingPathComponent(path, isDirectory: true)
                .standardizedFileURL
            let standardizedRoot = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
            guard resolved.path == standardizedRoot.path || resolved.path.hasPrefix(standardizedRoot.path + "/") else { return false }
            return isDirectory(at: resolved.path)
        case let .absolute(path):
            return isStandardAbsoluteDirectory(path)
        }
    }

    private func isExecutableRegularFile(at path: String) -> Bool {
        guard !isDirectory(at: path) else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }

    private func isDirectory(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isValidEnvironmentKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
}
