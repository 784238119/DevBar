import DevBarCore
import SwiftUI

struct WorkspaceCardView: View {
    let workspace: WorkspaceConfig
    let states: [UUID: ServiceState]
    let toggleService: (UUID) -> Void
    let startAll: () -> Void
    let stopAll: () -> Void

    @State private var isExpanded: Bool

    init(
        workspace: WorkspaceConfig,
        states: [UUID: ServiceState],
        initiallyExpanded: Bool,
        toggleService: @escaping (UUID) -> Void,
        startAll: @escaping () -> Void,
        stopAll: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.states = states
        self.toggleService = toggleService
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
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Text(String(workspace.name.prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                LinearGradient(
                                    colors: [Color(devBarHex: workspace.tintHex), DevBarTheme.accentEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(DevBarTheme.textPrimary)
                            Text("\(workspace.services.count) 个服务 · \(allStopped ? "全部已停止" : "\(activeCount) 个运行中")")
                                .font(.system(size: 11))
                                .foregroundStyle(DevBarTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.startAll.\(workspace.id.uuidString)")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .frame(width: 34, height: 34)
                }
            }
            .padding(18)

            if isExpanded {
                Divider()
                    .overlay(DevBarTheme.separator.opacity(0.7))
                    .padding(.horizontal, 14)

                VStack(spacing: 0) {
                    ForEach(Array(workspace.services.enumerated()), id: \.element.id) { index, service in
                        ServiceRowView(
                            service: service,
                            state: states[service.id] ?? .stopped,
                            toggle: { toggleService(service.id) }
                        )
                        if index < workspace.services.count - 1 {
                            Divider()
                                .overlay(DevBarTheme.separator.opacity(0.55))
                                .padding(.leading, 50)
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: DevBarTheme.majorRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DevBarTheme.majorRadius, style: .continuous)
                .stroke(DevBarTheme.separator.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: DevBarTheme.surfaceShadow, radius: 14, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.\(workspace.id.uuidString)")
    }
}
