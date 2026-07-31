import AppKit
import DevBarCore
import SwiftUI

struct LogWindowView: View {
    @Bindable var viewModel: LogViewModel
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DevBarTheme.separator.opacity(0.72))
            logContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(
            minWidth: 720,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 440,
            idealHeight: 600,
            maxHeight: .infinity
        )
        .background(background.ignoresSafeArea())
        .foregroundStyle(DevBarTheme.textPrimary)
        .task { await viewModel.start() }
        .confirmationDialog(
            "删除所选服务的日志历史？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓", role: .destructive) {
                Task { await viewModel.deleteHistoryConfirmed() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除磁盘日志；若后续操作失败，可从废纸篓恢复。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("logs.window")
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("服务日志")
                        .font(.system(size: 22, weight: .bold))
                    Text("最多显示最近 \(LogStore.defaultMaximumEntries) 条")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DevBarTheme.textSecondary)
                }

                Spacer()

                servicePicker
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DevBarTheme.textSecondary)
                    TextField("搜索已加载日志", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(DevBarTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(DevBarTheme.separator.opacity(0.76), lineWidth: 1)
                )
                .accessibilityIdentifier("logs.search")

                toolbarButton(
                    viewModel.isAutoScrollPaused ? "恢复滚动" : "暂停滚动",
                    systemImage: viewModel.isAutoScrollPaused ? "play.fill" : "pause.fill",
                    action: viewModel.toggleAutoScroll
                )
                .accessibilityIdentifier("logs.autoscroll")

                toolbarButton("清空视图", systemImage: "clear") {
                    Task { await viewModel.clearView() }
                }
                .accessibilityIdentifier("logs.clearView")

                toolbarButton("打开目录", systemImage: "folder") {
                    viewModel.openLogDirectory()
                }
                .accessibilityIdentifier("logs.openDirectory")

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("删除历史", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.86))
                .background(Color.red.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(viewModel.selectedService == nil)
                .accessibilityIdentifier("logs.deleteHistory")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(DevBarTheme.surfaceSubtle)
    }

    private var servicePicker: some View {
        Picker(
            "服务",
            selection: Binding(
                get: { viewModel.selectedServiceID },
                set: { serviceID in Task { await viewModel.selectService(serviceID) } }
            )
        ) {
            if viewModel.services.isEmpty {
                Text("暂无服务").tag(UUID?.none)
            } else {
                ForEach(viewModel.services) { service in
                    Text("\(service.workspaceName) · \(service.serviceName)")
                        .tag(Optional(service.serviceID))
                }
            }
        }
        .pickerStyle(.menu)
        .frame(width: 260)
        .disabled(viewModel.services.isEmpty)
        .accessibilityIdentifier("logs.servicePicker")
    }

    @ViewBuilder
    private var logContent: some View {
        if viewModel.services.isEmpty {
            ContentUnavailableView(
                "暂无可查看的服务",
                systemImage: "doc.text.magnifyingglass",
                description: Text("先在设置中添加服务，再从这里查看运行日志。")
            )
        } else if viewModel.isLoading && viewModel.loadedEntries.isEmpty {
            ProgressView("正在加载日志…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredEntries.isEmpty {
            ContentUnavailableView(
                viewModel.searchQuery.isEmpty ? "暂无日志" : "没有匹配结果",
                systemImage: viewModel.searchQuery.isEmpty ? "text.page" : "magnifyingglass",
                description: Text(viewModel.searchQuery.isEmpty ? "服务输出会实时显示在这里。" : "搜索只针对当前已加载的日志。")
            )
        } else {
            TerminalOutputView(viewModel: viewModel)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let notice = viewModel.notice {
                switch notice {
                case let .success(message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case let .failure(message):
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Text("已加载 \(viewModel.loadedEntries.count) 条")
                    .foregroundStyle(DevBarTheme.textSecondary)
                if !viewModel.searchQuery.isEmpty {
                    Text("匹配 \(viewModel.filteredEntries.count) 条")
                        .foregroundStyle(DevBarTheme.textSecondary)
                }
            }
            Spacer()
            if viewModel.isAutoScrollPaused {
                Label("自动滚动已暂停", systemImage: "pause.circle.fill")
                    .foregroundStyle(Color.orange.opacity(0.9))
            } else {
                Label("自动滚动", systemImage: "arrow.down.to.line.compact")
                    .foregroundStyle(DevBarTheme.textSecondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 22)
        .frame(height: 42)
        .background(DevBarTheme.surfaceSubtle)
        .overlay(alignment: .top) { Divider().overlay(DevBarTheme.separator.opacity(0.65)) }
    }

    private func toolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DevBarTheme.separator.opacity(0.74), lineWidth: 1)
        )
        .disabled(viewModel.selectedService == nil)
    }

    private var background: some View {
        ZStack {
            DevBarTheme.background
            RadialGradient(
                colors: [DevBarTheme.accentStart.opacity(0.08), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 600
            )
            RadialGradient(
                colors: [DevBarTheme.accentEnd.opacity(0.09), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 620
            )
        }
    }
}

private struct TerminalOutputView: NSViewRepresentable {
    let entries: [LogEntry]
    let followsOutput: Bool

    init(viewModel: LogViewModel) {
        entries = viewModel.filteredEntries
        followsOutput = !viewModel.isAutoScrollPaused
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.backgroundColor = NSColor(LogTerminalTheme.background)
        textView.textColor = NSColor(LogTerminalTheme.text)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(LogTerminalTheme.background)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard entries != context.coordinator.entries else { return }

        let wasAtBottom = isAtBottom(scrollView)
        let storage = textView.textStorage ?? NSTextStorage()
        if entries.starts(with: context.coordinator.entries) {
            let suffix = entries.dropFirst(context.coordinator.entries.count).map(\.text).joined()
            storage.append(attributedTerminalText(suffix))
        } else {
            let output = entries.map(\.text).joined()
            storage.setAttributedString(attributedTerminalText(output))
        }
        context.coordinator.entries = entries

        if followsOutput && wasAtBottom {
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }

    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        return scrollView.contentView.bounds.maxY >= documentView.bounds.maxY - 2
    }

    private func attributedTerminalText(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor(LogTerminalTheme.text),
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ]
        )
    }

    final class Coordinator {
        var entries: [LogEntry] = []
    }
}

private enum LogTerminalTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.078)
    static let text = Color(red: 0.88, green: 0.93, blue: 0.91)
}
