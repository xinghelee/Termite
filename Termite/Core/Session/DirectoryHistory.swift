import Foundation
import Observation

/// 目录历史(⌘O 跳转器数据源):OSC 7 上报的每次 cwd 变化都记一笔,
/// frecency(访问次数 × 新近度权重)排序,零配置版 zoxide。
@MainActor
@Observable
final class DirectoryHistory {
    static let shared = DirectoryHistory()

    struct Entry: Codable, Identifiable {
        var path: String
        var visits: Int
        var lastVisit: Date
        var id: String { path }

        var name: String { (path as NSString).lastPathComponent }
        var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    }

    private(set) var entries: [String: Entry] = [:]

    private static let key = "directory.history"
    private static let capacity = 500

    init() {
        load()
    }

    func record(path: String) {
        // 家目录是每个 shell 的起点,记了只会淹没有效信号
        guard path != FileManager.default.homeDirectoryForCurrentUser.path else { return }
        if var entry = entries[path] {
            entry.visits += 1
            entry.lastVisit = Date()
            entries[path] = entry
        } else {
            entries[path] = Entry(path: path, visits: 1, lastVisit: Date())
        }
        if entries.count > Self.capacity {
            // 淘汰分数最低的 10%
            let sorted = entries.values.sorted { score(of: $0) < score(of: $1) }
            for entry in sorted.prefix(Self.capacity / 10) {
                entries.removeValue(forKey: entry.path)
            }
        }
        save()
    }

    /// 查询:空串 → 按 frecency 全排;有词 → 模糊分 × frecency。已消失的目录过滤掉。
    func query(_ text: String, limit: Int = 12) -> [Entry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let scored: [(Entry, Double)] = entries.values.compactMap { entry in
            let frecency = score(of: entry)
            if trimmed.isEmpty { return (entry, frecency) }
            guard let match = FuzzyMatcher.bestScore(query: trimmed, fields: [entry.name, entry.displayPath]) else {
                return nil
            }
            return (entry, Double(match) * 1000 + frecency)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .lazy
            .map(\.0)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(limit)
            .map { $0 }
    }

    func score(of entry: Entry) -> Double {
        Self.frecencyScore(visits: entry.visits, ageSeconds: Date().timeIntervalSince(entry.lastVisit))
    }

    /// zoxide 式分段权重:越近访问权重越高
    nonisolated static func frecencyScore(visits: Int, ageSeconds: TimeInterval) -> Double {
        let weight: Double
        switch ageSeconds {
        case ..<3600: weight = 4
        case ..<86_400: weight = 2
        case ..<604_800: weight = 1
        default: weight = 0.25
        }
        return Double(visits) * weight
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.path, $0) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
