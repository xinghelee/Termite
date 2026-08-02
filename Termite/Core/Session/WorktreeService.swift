import Foundation

/// git worktree 操作:「每个 agent 一个 worktree」工作流的一等公民化。
/// 并行 agent 共用工作树会把 diff 混成一锅,分屏时顺手建 worktree 隔离。
/// 只在用户显式动作时调用,不进热路径;git 的报错原样带回给弹窗
enum WorktreeService {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// worktree 的目标:新建分支 / 检出已有分支 / 打开已存在的 worktree
    enum Target {
        case newBranch(String)
        case existing(String)
        case openWorktree(path: String, branch: String)

        var branchName: String {
            switch self {
            case .newBranch(let name): sanitized(name)
            case .existing(let name): name
            case .openWorktree(_, let branch): branch
            }
        }
    }

    /// 建 worktree:目录放仓库同级(<仓库名>-<分支名>),返回路径。
    /// 检出已有分支不带 -b;仅存在于远程的分支由 git DWIM 自动建同名本地跟踪分支
    static func add(near cwd: String, target: Target) async throws -> String {
        // 打开已有 worktree:目录本来就存在,必须先于「目录已存在」守卫返回
        if case .openWorktree(let existing, _) = target { return existing }
        let root = try await git(["rev-parse", "--show-toplevel"], in: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = target.branchName
        guard !branch.isEmpty else {
            throw Failure(message: String(localized: "名字不能为空"))
        }
        let parent = (root as NSString).deletingLastPathComponent
        let suffix = branch.replacingOccurrences(of: "/", with: "-")
        let path = parent + "/" + (root as NSString).lastPathComponent + "-" + suffix
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Failure(message: String(localized: "目录已存在:\(path)"))
        }
        switch target {
        case .newBranch: _ = try await git(["worktree", "add", "-b", branch, path], in: root)
        case .existing: _ = try await git(["worktree", "add", path, branch], in: root)
        case .openWorktree: preconditionFailure("已在入口返回")
        }
        return path
    }

    struct Branch: Identifiable, Hashable {
        let name: String
        let isRemote: Bool
        /// 该分支已被某个 worktree 检出时的目录(含主工作树);选它=直接进这个目录
        let worktreePath: String?
        var id: String { (isRemote ? "r:" : "l:") + name }
    }

    /// 全部分支:本地 + 远程(去 remote 前缀、与本地去重、剔除 HEAD),
    /// 并标注已被 worktree 检出的分支及其目录。
    /// 两次 git 进程,几千个 ref 也在几十毫秒;上层一次加载进内存做模糊搜索
    static func branches(near cwd: String) async throws -> [Branch] {
        let out = try await git(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], in: cwd)
        var locals: [String] = []
        var remotes: Set<String> = []
        for line in out.split(separator: "\n") {
            let ref = String(line)
            if ref.hasPrefix("refs/heads/") {
                locals.append(String(ref.dropFirst("refs/heads/".count)))
            } else if ref.hasPrefix("refs/remotes/") {
                let rest = ref.dropFirst("refs/remotes/".count)
                guard !rest.hasSuffix("/HEAD"), let slash = rest.firstIndex(of: "/") else { continue }
                remotes.insert(String(rest[rest.index(after: slash)...]))
            }
        }
        let checkedOut = try await checkedOutBranches(near: cwd)
        let localSet = Set(locals)
        return locals.sorted().map { Branch(name: $0, isRemote: false, worktreePath: checkedOut[$0]) }
            + remotes.subtracting(localSet).sorted().map { Branch(name: $0, isRemote: true, worktreePath: nil) }
    }

    /// 分支 → 检出它的 worktree 目录(worktree list --porcelain)
    private static func checkedOutBranches(near cwd: String) async throws -> [String: String] {
        let out = try await git(["worktree", "list", "--porcelain"], in: cwd)
        var map: [String: String] = [:]
        var currentPath: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path = currentPath {
                map[String(line.dropFirst("branch refs/heads/".count))] = path
            }
        }
        return map
    }

    /// 移除 worktree(force = 连未提交改动一起丢弃)。分支保留,合并后自行删除。
    /// remove 必须在主仓库上下文执行——worktree 的父目录不是仓库(踩过:fatal not a git repo);
    /// 主仓库路径从 worktree 的 .git 文件解析(gitdir: <主仓库>/.git/worktrees/<名>)
    static func remove(worktreePath: String, force: Bool) async throws {
        guard let contents = try? String(contentsOfFile: worktreePath + "/.git", encoding: .utf8),
              let gitdir = contents.split(separator: "\n")
                  .first(where: { $0.hasPrefix("gitdir:") })?
                  .dropFirst("gitdir:".count)
                  .trimmingCharacters(in: .whitespaces),
              let marker = gitdir.range(of: "/.git/worktrees/") else {
            throw Failure(message: String(localized: "不是链接 worktree:\(worktreePath)"))
        }
        let mainRoot = String(gitdir[..<marker.lowerBound])
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        _ = try await git(args, in: mainRoot)
    }

    /// 链接 worktree 的根目录(其 .git 是文件而非目录;主仓库返回 nil)。
    /// 纯文件系统探测,可在菜单构建等同步路径调用
    static func linkedWorktreeRoot(of path: String) -> String? {
        var dir = path
        for _ in 0..<24 {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir + "/.git", isDirectory: &isDirectory) {
                return isDirectory.boolValue ? nil : dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
        return nil
    }

    /// 分支名清洗:空白转 -,剔除 git 引用名非法字符
    static func sanitized(_ name: String) -> String {
        let collapsed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
        let banned = CharacterSet(charactersIn: "~^:?*[]\\!@{}\"'<>|;()$&#%")
        var cleaned = String(String.UnicodeScalarView(collapsed.unicodeScalars.filter { !banned.contains($0) }))
        while cleaned.hasPrefix("-") || cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") || cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned
    }

    private static func git(_ args: [String], in directory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(message: error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(message: message.isEmpty
                        ? String(localized: "git 退出码 \(process.terminationStatus)") : message))
                }
            }
        }
    }
}
