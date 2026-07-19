import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// 右侧文件浏览器:当前会话工作目录的文件树。
/// 目录单击展开/收起(子项懒加载);文本/代码文件单击进入面板内着色预览,
/// 图片/二进制走 Quick Look;双击用「打开程序」设置指定的应用(默认跟随系统)。
/// 右键可在 Finder 显示、复制路径、把路径插入终端;目录还可 cd 过去。
struct FileBrowserView: View {
    let session: TerminalSession
    let onClose: () -> Void

    @AppStorage("fileBrowser.showHidden") private var showHidden = false
    /// 面板宽度(拖左缘调整,持久化)
    @AppStorage("fileBrowser.panelWidth") private var storedWidth = 260.0
    @State private var dragStartWidth: Double?
    /// 自增触发整树重建(刷新按钮 / 显示隐藏文件切换)
    @State private var reloadToken = 0
    /// 面板内预览的文件(nil = 显示文件树)
    @State private var previewed: PreviewedFile?

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var rootPath: String? { session.workingDirectory }

    /// 预览代码时保证可读宽度
    private var effectiveWidth: CGFloat {
        CGFloat(previewed != nil ? max(storedWidth, 520) : storedWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            if let root = rootPath {
                ZStack {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            FileTreeLevel(
                                directory: root,
                                depth: 0,
                                showHidden: showHidden,
                                session: session,
                                onPreview: { preview($0) },
                                onNewFolder: { promptNewFolder(in: $0.path) }
                            )
                        }
                        .padding(6)
                    }
                    .id("\(root)#\(reloadToken)#\(showHidden)")
                    if let previewed {
                        FilePreviewScreen(file: previewed) {
                            self.previewed = nil
                        }
                        .background(theme.panelBackground)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("尚未获取到工作目录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("依赖 shell 集成(OSC 7),zsh 已自动注入")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .frame(width: effectiveWidth)
        .background(theme.panelBackground)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: previewed != nil)
        .onChange(of: session.workingDirectory) { _, _ in previewed = nil }
        // 左缘拖拽调宽(同 Git 面板:全局坐标系避免抖动)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.clear)
                .frame(width: 7)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = Double(effectiveWidth) }
                            let proposed = (dragStartWidth ?? 260) - Double(value.translation.width)
                            storedWidth = min(max(proposed, 200), 980)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
        }
    }

    /// 弹名字输入框,在 parent 下创建文件夹,成功后重载文件树
    private func promptNewFolder(in parent: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "新建文件夹")
        alert.informativeText = (parent as NSString).abbreviatingWithTildeInPath
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = String(localized: "文件夹名称")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "创建"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: (parent as NSString).appendingPathComponent(name),
                withIntermediateDirectories: false
            )
            reloadToken += 1
        } catch {
            let failure = NSAlert()
            failure.messageText = String(localized: "无法创建文件夹")
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    /// 点击文件的路由:文本/代码 → 面板内着色预览;其余(图片/PDF/二进制)→ Quick Look
    private func preview(_ entry: FileEntry) {
        if Self.isTextLike(entry.path) {
            previewed = PreviewedFile(name: entry.name, path: entry.path)
        } else {
            QuickLookController.shared.preview(URL(fileURLWithPath: entry.path))
        }
    }

    private static func isTextLike(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if CodeHighlighter.supports(fileExtension: ext) { return true }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
                || type.conforms(to: .pdf) || type.conforms(to: .archive) {
                return false
            }
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
        }
        // 无扩展名/未知类型:嗅探前 8KB,无 NUL 字节按文本对待(.zshrc 这类点文件走这里)
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 8192) else { return false }
        return !data.contains(0)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Label("文件", systemImage: "folder")
                .font(.system(size: 12, weight: .semibold))
            if let root = rootPath {
                Text((root as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help((root as NSString).abbreviatingWithTildeInPath)
            }
            Spacer()
            if let root = rootPath {
                PanelIconButton(symbol: "folder.badge.plus", help: String(localized: "新建文件夹")) {
                    promptNewFolder(in: root)
                }
            }
            PanelIconButton(
                symbol: showHidden ? "eye" : "eye.slash",
                help: String(localized: "显示/隐藏点文件"),
                tint: showHidden ? theme.accentColor : nil
            ) {
                showHidden.toggle()
            }
            PanelIconButton(symbol: "arrow.clockwise", help: String(localized: "刷新")) {
                reloadToken += 1
            }
            PanelIconButton(symbol: "xmark", help: String(localized: "关闭面板"), action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// 一层目录内容:读取排序后逐行渲染,展开的子目录递归下一层
private struct FileTreeLevel: View {
    let directory: String
    let depth: Int
    let showHidden: Bool
    let session: TerminalSession
    let onPreview: (FileEntry) -> Void
    let onNewFolder: (FileEntry) -> Void

    @State private var entries: [FileEntry]?
    @State private var expanded: Set<String> = []

    var body: some View {
        if let entries {
            if entries.isEmpty, depth == 0 {
                Text("空目录")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }
            ForEach(entries) { entry in
                FileRow(
                    entry: entry,
                    depth: depth,
                    isExpanded: expanded.contains(entry.path),
                    session: session,
                    onPreview: { onPreview(entry) },
                    onNewFolder: { onNewFolder(entry) }
                ) {
                    if entry.isDirectory {
                        if expanded.contains(entry.path) {
                            expanded.remove(entry.path)
                        } else {
                            expanded.insert(entry.path)
                        }
                    }
                }
                if entry.isDirectory, expanded.contains(entry.path) {
                    FileTreeLevel(
                        directory: entry.path,
                        depth: depth + 1,
                        showHidden: showHidden,
                        session: session,
                        onPreview: onPreview,
                        onNewFolder: onNewFolder
                    )
                }
            }
        } else {
            Color.clear
                .frame(height: 1)
                .task { entries = Self.load(directory: directory, showHidden: showHidden) }
        }
    }

    /// 读目录:文件夹在前,各自按 Finder 习惯排序
    private static func load(directory: String, showHidden: Bool) -> [FileEntry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { showHidden || !$0.hasPrefix(".") }
            .map { name -> FileEntry in
                let path = (directory as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                return FileEntry(name: name, path: path, isDirectory: isDir.boolValue)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

private struct FileEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
}

private struct FileRow: View {
    let entry: FileEntry
    let depth: Int
    let isExpanded: Bool
    let session: TerminalSession
    let onPreview: () -> Void
    let onNewFolder: () -> Void
    let onTap: () -> Void

    @State private var hovering = false
    @AppStorage(SettingsKeys.fileOpenAppPath) private var openAppPath = ""

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        HStack(spacing: 5) {
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
            Text(entry.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if !entry.isDirectory {
                FileOpener.open(entry.path)
            }
        }
        .onTapGesture {
            if entry.isDirectory {
                onTap()
            } else {
                onPreview()
            }
        }
        .contextMenu {
            if entry.isDirectory {
                Button("在终端 cd 到此目录") {
                    // ^U 清行再输入,避免拼进用户已敲了一半的命令
                    session.sendText("\u{15}cd " + TermiteTerminalView.shellEscaped(entry.path) + "\n")
                    session.focusTerminal()
                }
                Button("在此新建文件夹") {
                    onNewFolder()
                }
            } else {
                Button("快速查看") {
                    QuickLookController.shared.preview(URL(fileURLWithPath: entry.path))
                }
                Button(openAppPath.isEmpty ? "用默认程序打开" : "用 \(FileOpener.displayName) 打开") {
                    FileOpener.open(entry.path)
                }
                Button("选择打开程序…") {
                    FileOpener.chooseApp { openAppPath = $0 }
                }
            }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            Divider()
            Button("插入路径到终端") {
                session.sendText(TermiteTerminalView.shellEscaped(entry.path))
                session.focusTerminal()
            }
            Button("复制路径") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.path, forType: .string)
            }
        }
    }

    private var icon: NSImage {
        NSWorkspace.shared.icon(forFile: entry.path)
    }
}

/// 面板内正在预览的文件
private struct PreviewedFile: Equatable {
    let name: String
    let path: String
}

/// 面板内代码/Markdown 预览:返回按钮 + 文件名 + 打开按钮;
/// 代码语法着色、可选中复制;.md 默认渲染(标题/列表/代码块),可切回源码。
private struct FilePreviewScreen: View {
    let file: PreviewedFile
    let onBack: () -> Void

    @State private var loaded: LoadedContent?
    @State private var note: String?
    @State private var renderMarkdown = true

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var isMarkdown: Bool {
        ["md", "markdown"].contains((file.path as NSString).pathExtension.lowercased())
    }

    private enum LoadedContent {
        case code(AttributedString)
        case markdown([MarkdownRenderer.Block])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                PanelIconButton(symbol: "chevron.left", help: String(localized: "返回文件树"), action: onBack)
                Text(file.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                Spacer()
                if isMarkdown {
                    PanelIconButton(
                        symbol: renderMarkdown ? "curlybraces" : "doc.richtext",
                        help: renderMarkdown ? String(localized: "查看源码") : String(localized: "渲染预览")
                    ) {
                        renderMarkdown.toggle()
                    }
                }
                PanelIconButton(symbol: "arrow.up.forward.app", help: "用 \(FileOpener.displayName) 打开") {
                    FileOpener.open(file.path)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider().overlay(theme.borderColor)
            switch loaded {
            case .code(let content):
                ScrollView {
                    Text(content)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            case .markdown(let blocks):
                ScrollView {
                    MarkdownBlocksView(blocks: blocks)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(theme.elevatedBackground)
            }
        }
        .task(id: "\(file.path)#\(renderMarkdown)") { await load() }
    }

    private func load() async {
        loaded = nil
        note = nil
        let path = file.path
        let theme = ThemeStore.shared.current
        let asMarkdown = isMarkdown && renderMarkdown
        let result: (LoadedContent, String?) = await Task.detached(priority: .userInitiated) {
            guard let data = FileManager.default.contents(atPath: path) else {
                return (.code(AttributedString(String(localized: "(无法读取文件)"))), nil)
            }
            let cap = 512 * 1024
            let text = String(decoding: data.prefix(cap), as: UTF8.self)
            let capNote = data.count > cap ? String(localized: "文件较大,仅预览前 512 KB") : nil
            if asMarkdown {
                return (.markdown(MarkdownRenderer.parse(text, theme: theme)), capNote)
            }
            let ext = (path as NSString).pathExtension
            let highlighted = CodeHighlighter.highlight(text, fileExtension: ext, theme: theme)
                ?? AttributedString(text)
            return (.code(highlighted), capNote)
        }.value
        loaded = result.0
        note = result.1
    }
}

/// 文件浏览器「打开」动作:可指定固定 .app(设置里配置),否则跟随系统默认程序
enum FileOpener {
    static var appURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: SettingsKeys.fileOpenAppPath),
              !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var displayName: String {
        guard let url = appURL else { return String(localized: "系统默认") }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let app = appURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func chooseApp(onPicked: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "选择用来打开文件的应用")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPicked(url.path)
        }
    }
}

/// Quick Look 预览:单例持有当前预览 URL,面板开着时点别的文件就地切换
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()

    private var url: URL?

    func preview(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { (url ?? URL(fileURLWithPath: "/")) as NSURL }
    }
}
