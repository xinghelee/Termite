import SwiftUI

/// 会话列表:Mac 端所有窗口的所有 pane,点卡片进终端。
/// 3 秒轮询刷新(仅本页在前台时),下拉手动刷新。
struct SessionListView: View {
    @Environment(ConnectionStore.self) private var store
    let client: RemoteClient

    @State private var openSession: RemoteSessionSummary?

    var body: some View {
        NavigationStack {
            Group {
                if client.sessions.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Termite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("重新配对", systemImage: "qrcode.viewfinder") {
                            client.shutdown()
                            store.endpoint = nil
                        }
                        Button("刷新", systemImage: "arrow.clockwise") {
                            client.requestList()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(item: $openSession) { session in
                TerminalScreenView(client: client, session: session)
            }
        }
        .task {
            while !Task.isCancelled {
                if openSession == nil { client.requestList() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var list: some View {
        List(client.sessions) { session in
            Button {
                guard session.alive else { return }
                openSession = session
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(badgeColor(session))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(session.cwd ?? session.shell)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if session.alive {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestList() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有打开的会话", systemImage: "terminal")
        } description: {
            Text(client.phase == .connected ? "在 Mac 上开个终端标签就会出现在这里" : "正在连接 \(store.endpoint?.displayName ?? "")…")
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(client.phase == .connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(store.endpoint?.host ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func badgeColor(_ session: RemoteSessionSummary) -> Color {
        if !session.alive { return .red }
        if session.attention != nil { return .orange }
        if session.running { return .green }
        return Color(.systemGray4)
    }
}
