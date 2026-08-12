import DevBarCore
import SwiftUI

struct ServiceRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let service: ServiceConfig
    let state: ServiceState
    let residentBytes: UInt64?
    let openLogs: () -> Void
    let toggle: () -> Void

    private var isActive: Bool {
        switch state {
        case .starting, .running, .ready, .unready, .stopping: true
        case .stopped, .failed: false
        }
    }

    private var presentation: (label: String, color: Color) {
        switch state {
        case .stopped: ("已停止", .secondary)
        case .starting: ("启动中", .orange)
        case .running: ("运行中", .green)
        case .ready: ("已就绪", .green)
        case .unready: ("等待就绪", .orange)
        case .stopping: ("停止中", .orange)
        case .failed: ("启动失败", .red)
        }
    }

    private var stateAnimationKey: String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .ready: "ready"
        case .unready: "unready"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }

    private var serviceSymbol: String {
        let command = service.command.lowercased()
        if command.contains("java") || command.contains("mvn") || command.contains("gradle") {
            return "cup.and.saucer.fill"
        }
        if command.contains("npm") || command.contains("pnpm") || command.contains("yarn") || command.contains("node") {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "terminal.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: serviceSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? DevBarTheme.accentMiddle : Color.green)
                .frame(width: 34, height: 34)
                .background(DevBarTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DevBarTheme.textPrimary)
                    .lineLimit(1)
                Label(memoryText, systemImage: "memorychip")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DevBarTheme.textSecondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .accessibilityLabel("内存占用 \(memoryText)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Circle()
                    .fill(presentation.color)
                    .frame(width: 7, height: 7)
                    .frame(width: 12, height: 12)
                Text(presentation.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DevBarTheme.textSecondary)
                    .contentTransition(.opacity)
            }
            .animation(reduceMotion ? nil : DevBarTheme.stateAnimation, value: stateAnimationKey)

            HStack(spacing: 4) {
                Button(action: openLogs) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(DevBarTheme.textSecondary)
                .help("查看 \(service.name) 日志")
                .accessibilityLabel("查看 \(service.name) 日志")
                .accessibilityIdentifier("service.logs.\(service.id.uuidString)")

                Divider()
                    .frame(height: 14)
                    .overlay(DevBarTheme.separator.opacity(0.7))

                Button(action: toggle) {
                    Image(systemName: isActive ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(isActive ? Color.red : DevBarTheme.accentMiddle)
                .accessibilityLabel(isActive ? "停止 \(service.name)" : "启动 \(service.name)")
                .accessibilityIdentifier("service.toggle.\(service.id.uuidString)")
            }
            .buttonStyle(DevBarPressButtonStyle())
            .background(DevBarTheme.surfaceStrong, in: Capsule())
            .overlay(Capsule().stroke(DevBarTheme.separator.opacity(0.82), lineWidth: 1))
            .animation(reduceMotion ? nil : DevBarTheme.stateAnimation, value: stateAnimationKey)
        }
        .padding(.vertical, 11)
    }

    private var memoryText: String {
        guard isActive else { return "内存 --" }
        guard let residentBytes, residentBytes > 0 else { return "内存 计算中" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(residentBytes), countStyle: .memory)
        return "内存 \(formatted)"
    }
}
