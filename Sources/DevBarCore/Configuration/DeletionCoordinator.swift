import Darwin
import Foundation

public protocol ConfigurationPersisting: Sendable {
    func persist(_ configuration: AppConfig) async throws
}

extension ConfigurationStore: ConfigurationPersisting {
    public func persist(_ configuration: AppConfig) async throws {
        try save(configuration)
    }
}

public enum ConfigurationDeletionTarget: Equatable, Sendable {
    case service(workspaceID: UUID, serviceID: UUID)
    case workspace(workspaceID: UUID)
}

public enum DeletedLogsRecovery: Equatable, Sendable {
    /// The log directory was moved successfully and can be restored from the user's Trash.
    case recoverableFromTrash
    /// No matching log directory existed, so there is no log data to restore.
    case noLogDirectoryExisted
}

public enum ConfigurationDeletionResult: Equatable, Sendable {
    case deleted(configuration: AppConfig)
    case trashFailed(originalConfiguration: AppConfig, message: String)
    case configurationSaveFailed(
        originalConfiguration: AppConfig,
        proposedConfiguration: AppConfig,
        logsRecovery: DeletedLogsRecovery,
        message: String
    )
}

public enum DeletionCoordinatorError: Error, Equatable, Sendable, LocalizedError {
    case workspaceNotFound(UUID)
    case serviceNotFound(UUID)
    case unsafeLogPath(String)
    case trashFailed(recoverableItemCount: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case let .workspaceNotFound(id):
            "Workspace \(id.uuidString) no longer exists."
        case let .serviceNotFound(id):
            "Service \(id.uuidString) no longer exists."
        case let .unsafeLogPath(path):
            "DevBar refused to move an unsafe log path to Trash: \(path)."
        case let .trashFailed(recoverableItemCount, message):
            if recoverableItemCount == 0 {
                "Logs were not moved to Trash, so DevBar kept the configuration unchanged. \(message)"
            } else {
                "DevBar kept the configuration unchanged. \(recoverableItemCount) earlier log folder(s) were moved and can be restored from Trash. \(message)"
            }
        }
    }
}

/// Performs the irreversible-looking portion of configuration deletion as a recoverable,
/// ordered transaction: move the exact UUID-derived logs first, then persist configuration.
public actor DeletionCoordinator {
    private let paths: AppPaths
    private let trasher: any Trashing
    private let configurationStore: any ConfigurationPersisting

    public init(
        paths: AppPaths,
        trasher: any Trashing = FileManagerTrasher(),
        configurationStore: any ConfigurationPersisting
    ) {
        self.paths = paths
        self.trasher = trasher
        self.configurationStore = configurationStore
    }

    public func delete(
        _ target: ConfigurationDeletionTarget,
        from originalConfiguration: AppConfig
    ) async throws -> ConfigurationDeletionResult {
        let proposedConfiguration = try removing(target, from: originalConfiguration)
        let logTarget = try resolveLogTarget(for: target)

        let logsRecovery: DeletedLogsRecovery
        switch try inspectLogTarget(logTarget, for: target) {
        case .missing:
            logsRecovery = .noLogDirectoryExisted
        case .directory:
            do {
                try await trasher.moveToTrash(logTarget)
                logsRecovery = .recoverableFromTrash
            } catch {
                return .trashFailed(
                    originalConfiguration: originalConfiguration,
                    message: "Logs were not moved to Trash, so DevBar kept the configuration unchanged. \(error.localizedDescription)"
                )
            }
        }

        do {
            try await configurationStore.persist(proposedConfiguration)
            return .deleted(configuration: proposedConfiguration)
        } catch {
            let recoveryMessage: String
            switch logsRecovery {
            case .recoverableFromTrash:
                recoveryMessage = "The configuration was not changed. The moved logs can be restored from Trash before retrying."
            case .noLogDirectoryExisted:
                recoveryMessage = "The configuration was not changed. No matching log directory existed."
            }
            return .configurationSaveFailed(
                originalConfiguration: originalConfiguration,
                proposedConfiguration: proposedConfiguration,
                logsRecovery: logsRecovery,
                message: "\(recoveryMessage) \(error.localizedDescription)"
            )
        }
    }

    /// Moves log directories for every workspace/service removed between two settings
    /// snapshots. Persistence is deliberately left to AppState so disk and observable
    /// configuration are adopted through one source of truth.
    @discardableResult
    public func prepareConfigurationChanges(
        from originalConfiguration: AppConfig,
        to proposedConfiguration: AppConfig
    ) async throws -> Int {
        let targets = deletionTargets(from: originalConfiguration, to: proposedConfiguration)
        var movedItemCount = 0
        for target in targets {
            do {
                if try await trashLogs(for: target) == .recoverableFromTrash {
                    movedItemCount += 1
                }
            } catch let error as DeletionCoordinatorError {
                if case let .trashFailed(_, message) = error {
                    throw DeletionCoordinatorError.trashFailed(
                        recoverableItemCount: movedItemCount,
                        message: message
                    )
                }
                throw error
            } catch {
                throw DeletionCoordinatorError.trashFailed(
                    recoverableItemCount: movedItemCount,
                    message: error.localizedDescription
                )
            }
        }
        return movedItemCount
    }

    /// Moves only the exact UUID-derived log directory. This is also used by the log
    /// window, where deleting history must not delete the service configuration.
    @discardableResult
    public func trashLogs(
        for target: ConfigurationDeletionTarget
    ) async throws -> DeletedLogsRecovery {
        let logTarget = try resolveLogTarget(for: target)
        switch try inspectLogTarget(logTarget, for: target) {
        case .missing:
            return .noLogDirectoryExisted
        case .directory:
            do {
                try await trasher.moveToTrash(logTarget)
                return .recoverableFromTrash
            } catch {
                throw DeletionCoordinatorError.trashFailed(
                    recoverableItemCount: 0,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func removing(
        _ target: ConfigurationDeletionTarget,
        from configuration: AppConfig
    ) throws -> AppConfig {
        var proposed = configuration
        switch target {
        case let .workspace(workspaceID):
            guard let index = proposed.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                throw DeletionCoordinatorError.workspaceNotFound(workspaceID)
            }
            proposed.workspaces.remove(at: index)
        case let .service(workspaceID, serviceID):
            guard let workspaceIndex = proposed.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                throw DeletionCoordinatorError.workspaceNotFound(workspaceID)
            }
            guard let serviceIndex = proposed.workspaces[workspaceIndex].services.firstIndex(where: { $0.id == serviceID }) else {
                throw DeletionCoordinatorError.serviceNotFound(serviceID)
            }
            proposed.workspaces[workspaceIndex].services.remove(at: serviceIndex)
        }
        return proposed
    }

    private func deletionTargets(
        from originalConfiguration: AppConfig,
        to proposedConfiguration: AppConfig
    ) -> [ConfigurationDeletionTarget] {
        let proposedWorkspaceIDs = Set(proposedConfiguration.workspaces.map(\.id))
        var targets: [ConfigurationDeletionTarget] = []

        for workspace in originalConfiguration.workspaces {
            if !proposedWorkspaceIDs.contains(workspace.id) {
                targets.append(.workspace(workspaceID: workspace.id))
                continue
            }
            guard let proposedWorkspace = proposedConfiguration.workspaces.first(where: { $0.id == workspace.id }) else {
                continue
            }
            let proposedServiceIDs = Set(proposedWorkspace.services.map(\.id))
            for service in workspace.services where !proposedServiceIDs.contains(service.id) {
                targets.append(.service(workspaceID: workspace.id, serviceID: service.id))
            }
        }
        return targets
    }

    private func resolveLogTarget(for target: ConfigurationDeletionTarget) throws -> URL {
        let root = paths.logsRootURL.standardizedFileURL
        let resolved: URL
        switch target {
        case let .workspace(workspaceID):
            resolved = root.appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true).standardizedFileURL
        case let .service(workspaceID, serviceID):
            resolved = root
                .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(serviceID.uuidString.lowercased(), isDirectory: true)
                .standardizedFileURL
        }
        guard resolved.path != root.path, resolved.path.hasPrefix(root.path + "/") else {
            throw DeletionCoordinatorError.unsafeLogPath(resolved.path)
        }
        return resolved
    }

    private enum LogTargetInspection {
        case missing
        case directory
    }

    private enum FileSystemNode {
        case missing
        case directory
        case symbolicLink
        case other
    }

    private func inspectLogTarget(
        _ target: URL,
        for deletionTarget: ConfigurationDeletionTarget
    ) throws -> LogTargetInspection {
        let root = paths.logsRootURL.standardizedFileURL
        switch node(at: root) {
        case .missing:
            return .missing
        case .directory:
            break
        case .symbolicLink, .other:
            throw DeletionCoordinatorError.unsafeLogPath(root.path)
        }

        let workspaceID: UUID
        switch deletionTarget {
        case let .workspace(id), let .service(id, _): workspaceID = id
        }
        let workspaceDirectory = root
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL

        switch node(at: workspaceDirectory) {
        case .missing:
            return .missing
        case .directory:
            break
        case .symbolicLink, .other:
            throw DeletionCoordinatorError.unsafeLogPath(workspaceDirectory.path)
        }

        if case .workspace = deletionTarget {
            return .directory
        }

        switch node(at: target) {
        case .missing:
            return .missing
        case .directory:
            return .directory
        case .symbolicLink, .other:
            throw DeletionCoordinatorError.unsafeLogPath(target.path)
        }
    }

    private func node(at url: URL) -> FileSystemNode {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            return errno == ENOENT ? .missing : .other
        }
        switch information.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symbolicLink
        default: return .other
        }
    }
}
