import DevBarCore
import SwiftUI

struct ServiceEditorSheet: View {
    @Bindable var viewModel: SettingsViewModel
    let workspaceID: UUID
    private let serviceID: UUID?
    @State private var service: ServiceConfig

    init(
        viewModel: SettingsViewModel,
        workspaceID: UUID,
        draft: ServiceEditorDraft
    ) {
        self.viewModel = viewModel
        self.workspaceID = workspaceID
        serviceID = draft.serviceID
        _service = State(initialValue: draft.service)
    }

    private var locked: Bool { viewModel.isLocked(workspaceID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(serviceID == nil ? "添加服务" : "编辑服务")
                        .font(.system(size: 19, weight: .bold))
                    Text("命令通过非交互 zsh 在前台运行")
                        .font(.system(size: 11))
                        .foregroundStyle(DevBarTheme.textSecondary)
                }
                Spacer()
                Button {
                    viewModel.endServiceEditing()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(DevBarTheme.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    basics
                    command
                    environment
                    health
                }
                .padding(20)
            }

            Divider().overlay(DevBarTheme.separator)
            HStack {
                if locked {
                    Label("运行中：目录和环境变量已锁定", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("取消") {
                    viewModel.endServiceEditing()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                Button("保存服务") {
                    let draft = ServiceEditorDraft(serviceID: serviceID, service: service)
                    Task {
                        _ = await viewModel.commitServiceEditor(
                            workspaceID: workspaceID,
                            draft: draft
                        )
                        viewModel.endServiceEditing()
                    }
                }
                .buttonStyle(SettingsGradientButtonStyle())
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
        }
        .frame(width: 640, height: 610)
        .background(DevBarTheme.background)
        .accessibilityIdentifier("service.editor")
    }

    private var basics: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 11) {
                Label("基本信息", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                TextField("服务名称", text: $service.name)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Text(directoryText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                    .frame(height: 32)
                        .background(DevBarTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button("选择目录") {
                        Task {
                            service = await viewModel.chooseServiceDirectory(
                                workspaceID: workspaceID,
                                for: service
                            )
                        }
                    }
                    .disabled(locked)
                }

                Toggle("加入启动全部", isOn: $service.includeInStartAll)
                    .toggleStyle(.switch)
            }
        }
    }

    private var command: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("启动命令", systemImage: "terminal")
                    .font(.system(size: 14, weight: .bold))
                TextEditor(text: $service.command)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 64)
                    .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DevBarTheme.separator.opacity(0.8)))
                Text("例如：npm run dev 或 mvn spring-boot:run。不要使用需要 TTY 的交互命令。")
                    .font(.system(size: 10))
                    .foregroundStyle(DevBarTheme.textSecondary)
            }
        }
    }

    private var environment: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("服务环境变量", systemImage: "text.badge.plus")
                    .font(.system(size: 14, weight: .bold))
                EnvironmentEditor(
                    entries: $service.environment,
                    disabled: locked,
                    issueForIndex: { _ in nil }
                )
            }
        }
    }

    private var health: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 11) {
                Label("健康检查", systemImage: "heart.text.square")
                    .font(.system(size: 14, weight: .bold))
                Picker("类型", selection: healthKind) {
                    Text("无").tag(HealthKind.none)
                    Text("HTTP").tag(HealthKind.http)
                    Text("TCP").tag(HealthKind.tcp)
                }
                .pickerStyle(.segmented)

                switch healthKind.wrappedValue {
                case .none:
                    Text("进程持续运行 1 秒后视为运行中。")
                        .font(.system(size: 11))
                        .foregroundStyle(DevBarTheme.textSecondary)
                case .http:
                    TextField("http://127.0.0.1:8080/health", text: httpURL)
                        .textFieldStyle(.roundedBorder)
                case .tcp:
                    HStack {
                        TextField("主机", text: tcpHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("端口", value: tcpPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                    }
                }
            }
        }
    }

    private enum HealthKind: Hashable { case none, http, tcp }

    private var healthKind: Binding<HealthKind> {
        Binding {
            switch service.healthCheck {
            case .none: .none
            case .http: .http
            case .tcp: .tcp
            }
        } set: { kind in
            switch kind {
            case .none: service.healthCheck = .none
            case .http:
                service.healthCheck = .http(URL(string: "http://127.0.0.1:8080/health")!)
            case .tcp:
                service.healthCheck = .tcp(host: "127.0.0.1", port: 8080)
            }
        }
    }

    private var httpURL: Binding<String> {
        Binding {
            if case let .http(url) = service.healthCheck { return url.absoluteString }
            return ""
        } set: { text in
            service.healthCheck = .http(URL(string: text) ?? URL(string: "invalid")!)
        }
    }

    private var tcpHost: Binding<String> {
        Binding {
            if case let .tcp(host, _) = service.healthCheck { return host }
            return ""
        } set: { host in
            let port: Int
            if case let .tcp(_, currentPort) = service.healthCheck {
                port = currentPort
            } else {
                port = 8080
            }
            service.healthCheck = .tcp(host: host, port: port)
        }
    }

    private var tcpPort: Binding<Int> {
        Binding {
            if case let .tcp(_, port) = service.healthCheck { return port }
            return 8080
        } set: { port in
            let host: String
            if case let .tcp(currentHost, _) = service.healthCheck {
                host = currentHost
            } else {
                host = "127.0.0.1"
            }
            service.healthCheck = .tcp(host: host, port: port)
        }
    }

    private var directoryText: String {
        switch service.workingDirectory {
        case let .relative(path): "相对：\(path)"
        case let .absolute(path): "绝对：\(path)"
        }
    }
}
