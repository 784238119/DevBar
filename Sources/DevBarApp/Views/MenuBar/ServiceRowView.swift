import DevBarCore
import SwiftUI

struct ServiceRowView: View {
    let service: ServiceConfig
    let state: ServiceState
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
        HStack(spacing: 12) {
            Image(systemName: serviceSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? DevBarTheme.accentMiddle : Color.green)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DevBarTheme.textPrimary)
                    .lineLimit(1)
                Text(service.command)
                    .font(.system(size: 11))
                    .foregroundStyle(DevBarTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Circle()
                    .fill(presentation.color)
                    .frame(width: 7, height: 7)
                Text(presentation.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DevBarTheme.textSecondary)
            }

            Button(action: toggle) {
                Image(systemName: isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isActive ? Color.red : DevBarTheme.textSecondary)
            .background(Color.white.opacity(0.58), in: Circle())
            .overlay(Circle().stroke(DevBarTheme.separator.opacity(0.9), lineWidth: 1))
            .accessibilityLabel(isActive ? "停止 \(service.name)" : "启动 \(service.name)")
            .accessibilityIdentifier("service.toggle.\(service.id.uuidString)")
        }
        .padding(.vertical, 16)
    }
}
