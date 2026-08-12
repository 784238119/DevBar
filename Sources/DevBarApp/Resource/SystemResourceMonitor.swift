import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class SystemResourceMonitor {
    private(set) var systemMemoryUsage: Double = 0
    private(set) var applicationResidentBytes: UInt64 = 0
    private(set) var serviceResidentBytes: [UUID: UInt64] = [:]

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var systemMemoryUsageText: String {
        systemMemoryUsage.formatted(.percent.precision(.fractionLength(0)))
    }

    var applicationMemoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(applicationResidentBytes), countStyle: .memory)
    }

    deinit { refreshTask?.cancel() }

    func start(serviceProcessGroups: @escaping @MainActor () -> [UUID: Int32] = { [:] }) async {
        guard refreshTask == nil else { return }
        refresh(serviceProcessGroups: serviceProcessGroups())
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.refresh(serviceProcessGroups: serviceProcessGroups())
            }
        }
    }

    private func refresh(serviceProcessGroups: [UUID: Int32]) {
        applicationResidentBytes = Self.applicationResidentMemory()
        systemMemoryUsage = Self.systemMemoryFraction()
        serviceResidentBytes = serviceProcessGroups.mapValues(Self.processGroupResidentMemory)
    }

    private static func applicationResidentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static func systemMemoryFraction() -> Double {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return 0 }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        let usedBytes = usedPages * UInt64(pageSize)
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static func processGroupResidentMemory(_ processGroupID: Int32) -> UInt64 {
        guard processGroupID > 0 else { return 0 }
        let capacity = max(Int(proc_listallpids(nil, 0)), 1)
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let byteCount = Int32(processIDs.count * MemoryLayout<pid_t>.stride)
        let populatedBytes = processIDs.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, byteCount)
        }
        guard populatedBytes > 0 else { return 0 }

        let processCount = min(Int(populatedBytes) / MemoryLayout<pid_t>.stride, processIDs.count)
        return processIDs.prefix(processCount).reduce(into: UInt64(0)) { total, processID in
            guard processID > 0, getpgid(processID) == processGroupID else { return }
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) { usagePointer in
                let rawBuffer = UnsafeMutableRawPointer(usagePointer)
                    .assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(processID, RUSAGE_INFO_V2, rawBuffer)
            }
            guard result == 0 else { return }
            total += usage.ri_resident_size
        }
    }
}
