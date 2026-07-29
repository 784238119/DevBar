import DevBarCore
import SwiftUI

struct WorkspaceCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let workspace: WorkspaceConfig
    let states: [UUID: ServiceState]
    let toggleService: (UUID) -> Void
    let openLogs: (UUID) -> Void
    let startAll: () -> Void
    let stopAll: () -> Void

    @State private var isExpanded: Bool

    init(
        workspace: WorkspaceConfig,
        states: [UUID: ServiceState],
        initiallyExpanded: Bool,
        toggleService: @escaping (UUID) -> Void,
        openLogs: @escaping (UUID) -> Void,
        startAll: @escaping () -> Void,
        stopAll: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.states = states
        self.toggleService = toggleService
        self.openLogs = openLogs
        self.startAll = startAll
        self.stopAll = stopAll
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var activeCount: Int {
        workspace.services.filter { service in
            switch states[service.id] ?? .stopped {
            case .starting, .running, .ready, .unready, .stopping: true
            case .stopped, .failed: false
            }
        }.count
    }

    private var allStopped: Bool { activeCount == 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        WorkspaceIconContent(workspace: workspace, fontSize: 16, fontWeight: .semibold)
                            .frame(width: 38, height: 38)
                            .background(
                                LinearGradient(
                                    colors: [Color(devBarHex: workspace.tintHex), DevBarTheme.accentEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(DevBarTheme.textPrimary)
                            Text("\(workspace.services.count) 个服务 · \(allStopped ? "全部已停止" : "\(activeCount) 个运行中")")
                                .font(.system(size: 11))
                                .foregroundStyle(DevBarTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DevBarPressButtonStyle())

                if isExpanded {
                    Button(allStopped ? "启动全部" : "停止全部") {
                        allStopped ? startAll() : stopAll()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(allStopped ? AnyShapeStyle(DevBarTheme.accent) : AnyShapeStyle(Color.red.opacity(0.86)))
                    .clipShape(RoundedRectangle(cornerRadius: DevBarTheme.controlRadius, style: .continuous))
                    .buttonStyle(DevBarPressButtonStyle())
                    .accessibilityIdentifier("workspace.startAll.\(workspace.id.uuidString)")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .frame(width: 34, height: 34)
                }
            }
            .padding(16)

            if isExpanded {
                Divider()
                    .overlay(DevBarTheme.separator.opacity(0.7))
                    .padding(.horizontal, 14)

                VStack(spacing: 0) {
                    ForEach(Array(workspace.services.enumerated()), id: \.element.id) { index, service in
                        ServiceRowView(
                            service: service,
                            state: states[service.id] ?? .stopped,
                            openLogs: { openLogs(service.id) },
                            toggle: { toggleService(service.id) }
                        )
                        if index < workspace.services.count - 1 {
                            Divider()
                                .overlay(DevBarTheme.separator.opacity(0.55))
                                .padding(.leading, 50)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: DevBarTheme.majorRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DevBarTheme.majorRadius, style: .continuous)
                .stroke(DevBarTheme.separator.opacity(0.48), lineWidth: 0.75)
        )
        .shadow(color: DevBarTheme.surfaceShadow.opacity(0.72), radius: 16, y: 7)
        .animation(reduceMotion ? nil : DevBarTheme.stateAnimation, value: activeCount)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.\(workspace.id.uuidString)")
    }
}
