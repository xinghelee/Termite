import AppKit
import Observation
import SwiftUI

/// 克隆输入的解析:owner/repo、GitHub 网页链接(含 /tree/main 等尾巴)、
/// github.com/owner/repo、任意 https/ssh git 地址都认
struct RepoReference: Equatable {
    let url: String
    let name: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git clone ") { text = String(text.dropFirst("git clone ".count)).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("gh repo clone ") { text = String(text.dropFirst("gh repo clone ".count)).trimmingCharacters(in: .whitespaces) }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        // GitHub 网页地址 / 不带协议的 github.com/…:只取 owner/repo 两段
        var githubPath: String?
        for prefix in ["https://github.com/", "http://github.com/", "https://www.github.com/", "github.com/"]
        where text.lowercased().hasPrefix(prefix) {
            githubPath = String(text.dropFirst(prefix.count))
        }
        if githubPath == nil, !text.contains(":"), !text.hasPrefix("/"), !text.hasPrefix("."),
           text.split(separator: "/").count == 2 {
            githubPath = text
        }
        if let path = githubPath {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            let repo = Self.stripGit(parts[1])
            guard Self.isValidSegment(parts[0]), Self.isValidSegment(repo) else { return nil }
            url = "https://github.com/\(parts[0])/\(repo).git"
            name = repo
            return
        }

        // 其余 git 地址原样交给 git:https://…、ssh://…、git@host:owner/repo
        guard text.contains("://") || text.range(of: #"^[\w.-]+@[\w.-]+:"#, options: .regularExpression) != nil else {
            return nil
        }
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        let repo = Self.stripGit(last)
        guard Self.isValidSegment(repo) else { return nil }
        url = text
        name = repo
    }

    private static func stripGit(_ s: String) -> String {
        s.hasSuffix(".git") ? String(s.dropLast(4)) : s
    }

    private static func isValidSegment(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".."
            && s.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}

/// 一次后台 git clone:实时解析 --progress 输出,可取消。
/// 不给 git 交互的机会(GIT_TERMINAL_PROMPT=0、ssh BatchMode):
/// 没有终端可答,问密码只会永远挂住;失败时把 git 的原话带回来
@MainActor
@Observable
final class RepoCloneJob {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var phase = ""
    private(set) var fraction: Double?

    private var process: Process?
    private var cancelled = false

    func start(_ ref: RepoReference, into target: String, completion: @escaping () -> Void) {
        guard state != .running else { return }
        state = .running
        phase = String(localized: "正在连接…")
        fraction = nil
        cancelled = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--progress", ref.url, target]
        process.currentDirectoryURL = URL(fileURLWithPath: (target as NSString).deletingLastPathComponent)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        // stderr 在后台队列到达;攒全文给报错用,最后一行给进度用
        let buffer = CloneOutputBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = buffer.append(data) else { return }
            Task { @MainActor in self?.updateProgress(line) }
        }
        process.terminationHandler = { [weak self] proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            let output = buffer.text
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                if self.cancelled {
                    self.state = .idle
                } else if status == 0 {
                    self.state = .idle
                    completion()
                } else {
                    self.state = .failed(Self.failureMessage(from: output))
                }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// git 收到 SIGTERM 会自己清掉克隆了一半的目录
    func cancel() {
        guard let process, process.isRunning else { return }
        cancelled = true
        process.terminate()
    }

    private func updateProgress(_ line: String) {
        guard state == .running else { return }
        // 形如 "Receiving objects:  45% (450/1000), 1.2 MiB | 3.4 MiB/s"
        if let colon = line.firstIndex(of: ":") {
            let label = String(line[..<colon]).replacingOccurrences(of: "remote", with: "").trimmingCharacters(in: .whitespaces)
            phase = Self.localizedPhase(label)
            if let match = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) {
                let digits = line[match].dropLast()
                if let pct = Double(digits) {
                    // 只有真正搬数据的两步给进度条,其余阶段转圈
                    fraction = label.hasPrefix("Receiving") || label.hasPrefix("Resolving") ? pct / 100 : nil
                }
            }
        }
    }

    private static func localizedPhase(_ label: String) -> String {
        switch label {
        case let s where s.hasPrefix("Receiving objects"): String(localized: "下载中")
        case let s where s.hasPrefix("Resolving deltas"): String(localized: "解析差异")
        case let s where s.hasPrefix("Updating files"): String(localized: "检出文件")
        case let s where s.hasPrefix("Enumerating") || s.hasPrefix("Counting") || s.hasPrefix("Compressing"):
            String(localized: "远端打包中")
        default: String(localized: "克隆中")
        }
    }

    /// 从 git 输出里挑出有用的那句;认得的几种常见失败给人话提示
    private static func failureMessage(from output: String) -> String {
        let lines = output
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let fatal = lines.last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("ERROR:") || $0.hasPrefix("error:") })
            ?? lines.last ?? String(localized: "git clone 失败")
        let lower = output.lowercased()
        if lower.contains("repository not found") || lower.contains("could not read username")
            || lower.contains("terminal prompts disabled") {
            return String(localized: "仓库不存在,或是私有仓库需要授权。私有仓库请先在终端里配置好 SSH key(或运行 gh auth login 后 gh auth setup-git),再用 git@github.com:owner/repo 形式的地址。")
                + "\n\n" + fatal
        }
        if lower.contains("permission denied (publickey)") || lower.contains("host key verification failed") {
            return String(localized: "SSH 认证失败:请确认 SSH key 已添加到 GitHub 并已加载到 ssh-agent。")
                + "\n\n" + fatal
        }
        return fatal
    }
}

/// 后台队列写、终止回调读的输出缓冲
private final class CloneOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// 追加一段,返回其中最后一条完整的进度行(--progress 用 \r 原地刷新)
    func append(_ chunk: Data) -> String? {
        lock.lock()
        data.append(chunk)
        lock.unlock()
        let text = String(decoding: chunk, as: UTF8.self)
        return text
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 「从 GitHub 克隆」弹层:填地址 → 选存放位置 → 克隆完成即固定到侧边栏并进入
struct CloneRepoView: View {
    let onClose: () -> Void

    @Environment(SessionManager.self) private var sessionManager
    @State private var input = ""
    @State private var parentDirectory = CloneRepoView.defaultParentDirectory
    @State private var job = RepoCloneJob()
    @FocusState private var fieldFocused: Bool

    private var theme: TerminalTheme { ThemeStore.shared.current }
    private static let parentKey = "clone.parentDirectory"

    private var reference: RepoReference? { RepoReference(input) }
    private var targetPath: String? {
        reference.map { (parentDirectory as NSString).appendingPathComponent($0.name) }
    }
    /// 目标目录已存在:是 git 仓库就直接添加,不是就拦住
    private var existingRepo: Bool {
        guard let targetPath else { return false }
        return FileManager.default.fileExists(atPath: (targetPath as NSString).appendingPathComponent(".git"))
    }
    private var occupied: Bool {
        guard let targetPath else { return false }
        return FileManager.default.fileExists(atPath: targetPath) && !existingRepo
    }
    private var isRunning: Bool { job.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label("克隆仓库", systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭")) { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(theme.borderColor)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("仓库地址")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "owner/repo 或 GitHub 链接"), text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($fieldFocused)
                        .disabled(isRunning)
                        .onSubmit(submit)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("存放位置")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(Self.abbreviated(targetPath ?? parentDirectory))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(String(localized: "更改…"), action: chooseParent)
                            .controlSize(.small)
                            .disabled(isRunning)
                    }
                }

                statusLine
                    .frame(minHeight: 32, alignment: .top)

                HStack {
                    Spacer()
                    if isRunning {
                        Button(String(localized: "取消克隆")) { job.cancel() }
                    }
                    Button(existingRepo ? String(localized: "添加到侧边栏") : String(localized: "克隆")) { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reference == nil || occupied || isRunning)
                }
            }
            .padding(16)
        }
        .frame(width: 460)
        .background(theme.panelBackground)
        .onAppear {
            fieldFocused = true
            // 剪贴板里刚好是仓库地址就预填(从浏览器复制完直接打开这里)
            if input.isEmpty, let clip = NSPasteboard.general.string(forType: .string),
               clip.count < 300, RepoReference(clip) != nil,
               clip.contains("github") || clip.contains("git@") || clip.contains(".git") {
                input = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch job.state {
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = job.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
                Text(job.phase)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ScrollView {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        case .idle:
            if !input.isEmpty, reference == nil {
                hint(String(localized: "认不出这个地址。支持 owner/repo、GitHub 链接、https 或 git@ 地址。"))
            } else if occupied {
                hint(String(localized: "该位置已有同名文件夹且不是 git 仓库,请换个存放位置。"))
            } else if existingRepo {
                hint(String(localized: "该仓库已在本地,将直接添加到侧边栏。"))
            } else {
                hint(String(localized: "克隆完成后自动固定到侧边栏并进入该目录。"))
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        guard !isRunning, let reference, let targetPath, !occupied else { return }
        UserDefaults.standard.set(parentDirectory, forKey: Self.parentKey)
        if existingRepo {
            finish(targetPath)
            return
        }
        job.start(reference, into: targetPath) {
            finish(targetPath)
        }
    }

    private func finish(_ path: String) {
        SidebarActions.addAndOpen([path], in: sessionManager)
        onClose()
    }

    private func close() {
        job.cancel()
        onClose()
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parentDirectory)
        panel.message = String(localized: "选择克隆到哪个文件夹下")
        if panel.runModal() == .OK, let url = panel.url {
            parentDirectory = url.path
        }
    }

    /// 上次用过的位置;没有则 ~/Developer(存在时),再退回主目录
    static var defaultParentDirectory: String {
        if let saved = UserDefaults.standard.string(forKey: parentKey),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["Developer", "Projects", "Code", "dev"] {
            let path = (home as NSString).appendingPathComponent(candidate)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
        }
        return home
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
