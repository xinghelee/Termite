import SwiftUI

/// 端口管理:本机监听中的 TCP 端口 + 占用进程,一键结束("3000 被谁占了"终结者)
struct PortsView: View {
    let onClose: () -> Void

    @State private var entries: [PortEntry] = []
    @State private var loading = true

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label("端口管理", systemImage: "network")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(entries.count) 个监听端口")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                PanelIconButton(symbol: "arrow.clockwise", help: String(localized: "刷新")) {
                    Task { await refresh() }
                }
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(theme.borderColor)

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text("没有监听中的 TCP 端口")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            PortRow(entry: entry) {
                                Task { await kill(entry, force: false) }
                            } forceKill: {
                                Task { await kill(entry, force: true) }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 360, idealHeight: 460, maxHeight: .infinity)
        .background(theme.panelBackground)
        .task { await refresh() }
    }

    private func refresh() async {
        entries = await PortMonitor.listeningPorts()
        loading = false
    }

    private func kill(_ entry: PortEntry, force: Bool) async {
        Darwin.kill(entry.pid, force ? SIGKILL : SIGTERM)
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }
}

private struct PortRow: View {
    let entry: PortEntry
    let kill: () -> Void
    let forceKill: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 10) {
            Text(":\(String(entry.port))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accentColor)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.command)
                    .font(.system(size: 12))
                Text("pid \(String(entry.pid)) · \(entry.address)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                if let url = URL(string: "http://localhost:\(entry.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在浏览器打开 localhost:\(String(entry.port))")
            Button(action: kill) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.85))
            .help("结束进程(SIGTERM;右键可强制)")
            .contextMenu {
                Button("强制结束(SIGKILL)", role: .destructive, action: forceKill)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : theme.elevatedBackground.opacity(0.5)))
        .onHover { hovering = $0 }
    }
}

// MARK: - 数据

struct PortEntry: Identifiable, Equatable {
    let pid: Int32
    let command: String
    let port: Int
    let address: String
    var id: String { "\(pid):\(port)" }
}

enum PortMonitor {
    /// lsof 列监听端口(仅当前用户可见的进程)
    static func listeningPorts() async -> [PortEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: parse(text))
            }
        }
    }

    /// lsof 标准表头输出:COMMAND PID USER ... NAME (LISTEN)
    /// NAME 形如 *:3000 / 127.0.0.1:5173 / [::1]:5173,后面还挂着 "(LISTEN)",
    /// 所以取「最后一个含 : 的列」而不是最后一列
    static func parse(_ text: String) -> [PortEntry] {
        var seen: Set<String> = []
        var result: [PortEntry] = []
        for line in text.components(separatedBy: "\n").dropFirst() where !line.isEmpty {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 9,
                  let pid = Int32(columns[1]),
                  let name = columns.last(where: { $0.contains(":") }),
                  let separator = name.lastIndex(of: ":"),
                  let port = Int(name[name.index(after: separator)...]) else { continue }
            let host = String(name[..<separator])
            let address = host == "*" ? "*" : host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let entry = PortEntry(pid: pid, command: columns[0], port: port, address: address)
            // IPv4/IPv6 各一行,去重
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result.sorted { $0.port < $1.port }
    }
}
