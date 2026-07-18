import Foundation

/// git 数据模型

struct GitCommit: Identifiable, Equatable {
    let hash: String
    let author: String
    let relativeDate: String
    let subject: String
    var id: String { hash }
}

struct GitFileChange: Identifiable, Equatable {
    enum Kind: String {
        case staged, unstaged, untracked, committed
    }

    let kind: Kind
    /// 单字母状态码:M/A/D/R/C/U/?
    let statusCode: String
    let path: String
    var added: Int?
    var removed: Int?

    var id: String { kind.rawValue + ":" + path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    /// 图片文件走预览而非文本 diff
    var isImage: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "icns", "ico"].contains(ext)
    }
}

struct GitStatusSnapshot: Equatable {
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var untracked: [GitFileChange] = []

    var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
    var totalCount: Int { staged.count + unstaged.count + untracked.count }
}

/// 异步跑 git 命令(绝对路径,不依赖 PATH)。所有查询只读,不改仓库状态。
enum GitService {

    static func run(_ args: [String], in directory: String) async -> String? {
        guard let data = await runData(args, in: directory) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 二进制安全版(图片预览等场景)
    static func runData(_ args: [String], in directory: String) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 || !data.isEmpty ? data : nil)
            }
        }
    }

    /// 单个文件的提交历史
    static func fileLog(path: String, in directory: String, limit: Int = 100) async -> [GitCommit] {
        let text = await run(["log", "-\(limit)", "--format=%h%x09%an%x09%cr%x09%s", "--", path], in: directory) ?? ""
        return GitParse.log(text)
    }

    // MARK: - 写操作(暂存区,面板按钮触发)

    static func stage(path: String, in directory: String) async {
        _ = await run(["add", "--", path], in: directory)
    }

    static func unstage(path: String, in directory: String) async {
        _ = await run(["restore", "--staged", "--", path], in: directory)
    }

    /// 丢弃改动:未跟踪 → 删除文件;已跟踪 → 还原工作区(必要时先取消暂存)
    static func discard(change: GitFileChange, in directory: String) async {
        switch change.kind {
        case .untracked:
            _ = await run(["clean", "-f", "--", change.path], in: directory)
        case .staged:
            _ = await run(["restore", "--staged", "--", change.path], in: directory)
            _ = await run(["restore", "--", change.path], in: directory)
        case .unstaged:
            _ = await run(["restore", "--", change.path], in: directory)
        case .committed:
            break
        }
    }

    /// 工作区状态(暂存/未暂存/未跟踪 + ± 行数统计)
    static func status(in directory: String) async -> GitStatusSnapshot {
        async let porcelain = run(["status", "--porcelain=v2"], in: directory)
        async let unstagedStat = run(["diff", "--numstat"], in: directory)
        async let stagedStat = run(["diff", "--cached", "--numstat"], in: directory)
        var snapshot = GitParse.porcelainV2(await porcelain ?? "")
        let unstagedCounts = GitParse.numstat(await unstagedStat ?? "")
        let stagedCounts = GitParse.numstat(await stagedStat ?? "")
        snapshot.unstaged = snapshot.unstaged.map { change in
            var change = change
            change.added = unstagedCounts[change.path]?.added
            change.removed = unstagedCounts[change.path]?.removed
            return change
        }
        snapshot.staged = snapshot.staged.map { change in
            var change = change
            change.added = stagedCounts[change.path]?.added
            change.removed = stagedCounts[change.path]?.removed
            return change
        }
        return snapshot
    }

    /// 最近提交
    static func log(in directory: String, limit: Int = 50) async -> [GitCommit] {
        let text = await run(["log", "-\(limit)", "--format=%h%x09%an%x09%cr%x09%s"], in: directory) ?? ""
        return GitParse.log(text)
    }

    /// 某次提交改动的文件(状态码 + ± 统计)
    static func commitFiles(hash: String, in directory: String) async -> [GitFileChange] {
        async let nameStatus = run(["show", hash, "--name-status", "--format="], in: directory)
        async let numstat = run(["show", hash, "--numstat", "--format="], in: directory)
        let entries = GitParse.nameStatus(await nameStatus ?? "")
        let counts = GitParse.numstat(await numstat ?? "")
        return entries.map { entry in
            GitFileChange(
                kind: .committed,
                statusCode: entry.code,
                path: entry.path,
                added: counts[entry.path]?.added,
                removed: counts[entry.path]?.removed
            )
        }
    }

    /// 单文件 diff 文本(unified)
    static func diff(for change: GitFileChange, commitHash: String?, in directory: String) async -> String {
        switch change.kind {
        case .untracked:
            // 未跟踪文件没有 diff:与 /dev/null 对比得到全新增视图
            return await run(["diff", "--no-color", "--no-index", "--", "/dev/null", change.path], in: directory) ?? ""
        case .staged:
            return await run(["diff", "--cached", "--no-color", "--", change.path], in: directory) ?? ""
        case .unstaged:
            return await run(["diff", "--no-color", "--", change.path], in: directory) ?? ""
        case .committed:
            guard let commitHash else { return "" }
            return await run(["show", commitHash, "--no-color", "--format=", "--", change.path], in: directory) ?? ""
        }
    }
}

/// git 输出解析(纯函数,可测)
enum GitParse {

    /// `git status --porcelain=v2`:
    /// "1 XY sub mH mI mW hH hI path"(普通)、"2 XY ... path\torig"(改名)、"u ..."(冲突)、"? path"(未跟踪)
    static func porcelainV2(_ text: String) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let tokens = line.components(separatedBy: " ")
            guard let first = tokens.first else { continue }
            switch first {
            case "1", "2":
                guard tokens.count > 2 else { continue }
                let xy = tokens[1]
                let pathStart = first == "1" ? 8 : 9
                guard tokens.count > pathStart else { continue }
                var path = tokens[pathStart...].joined(separator: " ")
                if first == "2", let tab = path.firstIndex(of: "\t") {
                    path = String(path[..<tab]) // 改名:新路径在 tab 前
                }
                let staged = String(xy.prefix(1))
                let unstaged = String(xy.suffix(1))
                if staged != "." {
                    snapshot.staged.append(GitFileChange(kind: .staged, statusCode: staged, path: path))
                }
                if unstaged != "." {
                    snapshot.unstaged.append(GitFileChange(kind: .unstaged, statusCode: unstaged, path: path))
                }
            case "u":
                guard tokens.count > 10 else { continue }
                let path = tokens[10...].joined(separator: " ")
                snapshot.unstaged.append(GitFileChange(kind: .unstaged, statusCode: "U", path: path))
            case "?":
                let path = tokens.dropFirst().joined(separator: " ")
                snapshot.untracked.append(GitFileChange(kind: .untracked, statusCode: "?", path: path))
            default:
                continue // '#' 分支头等
            }
        }
        return snapshot
    }

    /// `--numstat`:"added\tremoved\tpath"(二进制为 "-")
    static func numstat(_ text: String) -> [String: (added: Int, removed: Int)] {
        var result: [String: (Int, Int)] = [:]
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let added = Int(parts[0]) ?? 0
            let removed = Int(parts[1]) ?? 0
            result[parts[2]] = (added, removed)
        }
        return result
    }

    /// `git log --format=%h\t%an\t%cr\t%s`
    static func log(_ text: String) -> [GitCommit] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            return GitCommit(
                hash: parts[0],
                author: parts[1],
                relativeDate: parts[2],
                subject: parts[3...].joined(separator: "\t")
            )
        }
    }

    /// `--name-status`:"M\tpath"、"R100\told\tnew"
    static func nameStatus(_ text: String) -> [(code: String, path: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let first = parts.first, !first.isEmpty else { return nil }
            let code = String(first.prefix(1))
            let path = code == "R" || code == "C" ? parts.last! : parts[1]
            return (code, path)
        }
    }
}
