import SwiftUI
import UniformTypeIdentifiers

/// 项目侧边栏:常用工作目录列表,点击即在该目录打开/切换终端标签。
/// 支持 + 按钮选文件夹、拖拽文件夹进列表、右键移除。
struct SidebarView: View {
    @Environment(SessionManager.self) private var sessionManager
    @State private var store = ProjectStore.shared
    @State private var workspaceStore = WorkspaceStore.shared
    @State private var theme = ThemeStore.shared

    var body: some View {
        List {
            Section {
                ForEach(store.projects) { project in
                    ProjectRow(
                        project: project,
                        isActive: isActive(project),
                        open: { open(project) },
                        remove: { store.remove(project) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    store.move(fromOffsets: from, toOffset: to)
                }
            } header: {
                HStack {
                    Text("项目")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.current.secondaryText)
                    Spacer()
                    HeaderIconButton(symbol: "plus", help: String(localized: "添加项目文件夹")) {
                        pickFolder()
                    }
                    .padding(.trailing, 4)
                }
            }

            if store.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有项目")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("点「项目」旁的 + 选择文件夹,或把文件夹拖到这里。点击项目即在该目录打开终端标签。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.top, 2)
            }

            if WorkspaceStore.isEnabled {
                workspaceSection
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.current.sidebarBackground)
        // 右缘发丝线:与标题栏下方的结构线呼应,划清侧边栏与终端区
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.current.borderColor)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    store.add(path: url.path)
                    added = true
                }
            }
            return added
        }
    }

    /// 工作区区块(恢复布局 bug 修复前由 WorkspaceStore.isEnabled 隐藏)
    private var workspaceSection: some View {
        Section {
            ForEach(workspaceStore.workspaces) { workspace in
                WorkspaceRow(
                    workspace: workspace,
                    open: { sessionManager.openWorkspace(workspace) },
                    overwrite: { workspaceStore.overwrite(workspace, tabs: sessionManager.captureWorkspaceTabs()) },
                    remove: { workspaceStore.remove(workspace) }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if workspaceStore.workspaces.isEmpty {
                Text("把当前「标签 + 分屏」整套布局存成模板,一键恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } header: {
            HStack {
                Text("工作区")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.current.secondaryText)
                Spacer()
                HeaderIconButton(symbol: "plus.square.on.square", help: String(localized: "保存当前布局为工作区模板")) {
                    saveCurrentLayout()
                }
                .disabled(sessionManager.tabs.isEmpty)
                .padding(.trailing, 4)
            }
        }
    }

    /// 有标签的聚焦会话正处于该项目目录(或其子目录)时,侧边栏行点亮
    private func isActive(_ project: Project) -> Bool {
        guard let cwd = sessionManager.selected?.workingDirectory else { return false }
        return cwd == project.path || cwd.hasPrefix(project.path + "/")
    }

    private func open(_ project: Project) {
        sessionManager.openProject(path: project.path)
    }

    /// 保存当前布局:弹一个带输入框的确认框取名
    private func saveCurrentLayout() {
        let alert = NSAlert()
        alert.messageText = String(localized: "保存当前布局为工作区")
        alert.informativeText = String(localized: "包含所有标签的分屏结构、比例与各 pane 的工作目录。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = String(localized: "工作区名称")
        field.stringValue = sessionManager.selected?.displayTitle ?? String(localized: "布局 \(workspaceStore.workspaces.count + 1)")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "保存"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        workspaceStore.add(
            name: name.isEmpty ? String(localized: "未命名布局") : name,
            tabs: sessionManager.captureWorkspaceTabs()
        )
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "选择要固定到侧边栏的项目文件夹(左下角可新建)")
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.add(path: url.path)
            }
        }
    }
}

/// 侧边栏区块标题右侧的小图标按钮:悬停有圆形底色响应
private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let open: () -> Void
    let overwrite: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(workspace.tabs.count) 标签 · \(workspace.paneCount) pane")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("打开(追加标签)") { open() }
            Button("用当前布局覆盖") { overwrite() }
            Divider()
            Button("删除", role: .destructive, action: remove)
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let isActive: Bool
    let open: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 8) {
            // Finder 式裸图标:固定宽度对齐成列,活动态用强调色
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? theme.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(project.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isActive {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isActive ? theme.accentSoft : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("在此目录新开标签页") { open() }
            Button("在 Finder 中打开") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
            Divider()
            Button("从侧边栏移除", role: .destructive, action: remove)
        }
        .help(project.path)
    }
}
