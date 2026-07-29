import DevBarCore
import Foundation
import Observation

protocol LogWindowStoring: Sendable {
    func loadRecent(workspaceID: UUID, serviceID: UUID, limit: Int) async -> [LogEntry]
    func entries(serviceID: UUID) async -> [LogEntry]
    func clearView(serviceID: UUID) async
}

extension LogStore: LogWindowStoring {}

struct LogServiceDescriptor: Identifiable, Hashable, Sendable {
    let workspaceID: UUID
    let serviceID: UUID
    let workspaceName: String
    let serviceName: String

    var id: UUID { serviceID }

    init(workspaceID: UUID, serviceID: UUID, workspaceName: String, serviceName: String) {
        self.workspaceID = workspaceID
        self.serviceID = serviceID
        self.workspaceName = workspaceName
        self.serviceName = serviceName
    }

    static func all(in configuration: AppConfig) -> [LogServiceDescriptor] {
        configuration.workspaces.flatMap { workspace in
            workspace.services.map { service in
                LogServiceDescriptor(
                    workspaceID: workspace.id,
                    serviceID: service.id,
                    workspaceName: workspace.name,
                    serviceName: service.name
                )
            }
        }
    }
}

enum LogWindowNotice: Equatable {
    case failure(String)
    case success(String)
}

@MainActor
@Observable
final class LogViewModel {
    typealias OpenDirectoryAction = @MainActor (LogServiceDescriptor) -> Void
    typealias DeleteHistoryAction = @MainActor (LogServiceDescriptor) async throws -> Void

    let services: [LogServiceDescriptor]
    private(set) var selectedServiceID: UUID?
    private(set) var loadedEntries: [LogEntry] = []
    var searchQuery = ""
    private(set) var isAutoScrollPaused = false
    private(set) var isLoading = false
    private(set) var notice: LogWindowNotice?

    var selectedService: LogServiceDescriptor? {
        guard let selectedServiceID else { return nil }
        return services.first { $0.serviceID == selectedServiceID }
    }

    /// Search is intentionally in-memory only. Disk history is capped before this filter runs.
    var filteredEntries: [LogEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return loadedEntries }
        return loadedEntries.filter { entry in
            entry.text.localizedCaseInsensitiveContains(query)
                || entry.stream.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private let store: any LogWindowStoring
    private let openDirectoryAction: OpenDirectoryAction
    private let deleteHistoryAction: DeleteHistoryAction
    private let refreshInterval: Duration
    private var selectionGeneration: UInt64 = 0
    private var didStart = false
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?

    init(
        services: [LogServiceDescriptor],
        selectedServiceID: UUID? = nil,
        store: any LogWindowStoring,
        refreshInterval: Duration = .milliseconds(350),
        openDirectory: @escaping OpenDirectoryAction,
        deleteHistory: @escaping DeleteHistoryAction
    ) {
        self.services = services
        self.selectedServiceID = selectedServiceID.flatMap { requested in
            services.contains(where: { $0.serviceID == requested }) ? requested : nil
        } ?? services.first?.serviceID
        self.store = store
        self.refreshInterval = refreshInterval
        openDirectoryAction = openDirectory
        deleteHistoryAction = deleteHistory
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        await loadSelectedService()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let interval = self?.refreshInterval else { return }
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await self?.refreshCurrentEntries()
            }
        }
    }

    func selectService(_ serviceID: UUID?) async {
        guard serviceID != selectedServiceID else { return }
        selectedServiceID = serviceID.flatMap { requested in
            services.contains(where: { $0.serviceID == requested }) ? requested : nil
        }
        selectionGeneration &+= 1
        loadedEntries = []
        searchQuery = ""
        notice = nil
        await loadSelectedService()
    }

    func toggleAutoScroll() {
        isAutoScrollPaused.toggle()
    }

    func clearView() async {
        guard let selectedService else { return }
        selectionGeneration &+= 1
        await store.clearView(serviceID: selectedService.serviceID)
        loadedEntries = []
        notice = .success("已清空当前视图，磁盘日志未删除。")
    }

    func openLogDirectory() {
        guard let selectedService else { return }
        openDirectoryAction(selectedService)
    }

    func deleteHistoryConfirmed() async {
        guard let selectedService else { return }
        selectionGeneration &+= 1
        do {
            try await deleteHistoryAction(selectedService)
            loadedEntries = []
            notice = .success("日志历史已移入废纸篓。")
        } catch {
            notice = .failure(error.localizedDescription)
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func loadSelectedService() async {
        guard let selectedService else {
            loadedEntries = []
            isLoading = false
            return
        }
        let generation = selectionGeneration
        isLoading = true
        let entries = await store.loadRecent(
            workspaceID: selectedService.workspaceID,
            serviceID: selectedService.serviceID,
            limit: LogStore.defaultMaximumEntries
        )
        guard generation == selectionGeneration,
              selectedService.serviceID == selectedServiceID
        else { return }
        loadedEntries = Array(entries.suffix(LogStore.defaultMaximumEntries))
        isLoading = false
    }

    private func refreshCurrentEntries() async {
        guard let selectedService else { return }
        let generation = selectionGeneration
        let entries = await store.entries(serviceID: selectedService.serviceID)
        guard generation == selectionGeneration,
              selectedService.serviceID == selectedServiceID
        else { return }
        let latestEntries = Array(entries.suffix(LogStore.defaultMaximumEntries))
        guard latestEntries != loadedEntries else { return }
        loadedEntries = latestEntries
    }
}
