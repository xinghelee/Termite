import AppKit
import Foundation
import Observation
import SwiftUI

/// 侧边栏项目:一个常用工作目录
struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    /// 项目专属强调色(hex);nil = 跟随主题
    var accentHex: String?
    /// 所属工作区(SidebarSpace.id);nil = 未分组,所有工作区可见
    var spaceID: UUID?
}

/// 项目列表(侧边栏数据源):持久化在 UserDefaults(JSON)
@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var projects: [Project] = []

    private static let key = "sidebar.projects"

    init() {
        load()
    }

    func add(path: String) {
        let standardized = (path as NSString).standardizingPath
        guard !projects.contains(where: { $0.path == standardized }) else { return }
        // 新项目归入当前工作区(严格归属制,没有工作区时为 nil)
        projects.append(Project(
            name: (standardized as NSString).lastPathComponent,
            path: standardized,
            spaceID: SpaceStore.shared.selected?.id
        ))
        save()
    }

    func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    /// 项目行拖拽重排:把 dragged 移到 target 当前的位置(与标签 chip 同一套手感)。
    /// 直接在全量列表上搬——拖拽两端必定同属一个工作区,不可见项目的相对位置不受影响
    func move(_ dragged: UUID, before targetID: UUID) {
        guard dragged != targetID,
              let from = projects.firstIndex(where: { $0.id == dragged }) else { return }
        let project = projects.remove(at: from)
        let insertAt = projects.firstIndex { $0.id == targetID } ?? min(from, projects.count)
        projects.insert(project, at: insertAt)
        save()
    }

    /// 向下拖越线用:把 dragged 移到 target 之后(与标签 chip 的 moveTab(after:) 对称)
    func move(_ dragged: UUID, after targetID: UUID) {
        guard dragged != targetID,
              let from = projects.firstIndex(where: { $0.id == dragged }) else { return }
        let project = projects.remove(at: from)
        let insertAt = projects.firstIndex { $0.id == targetID }.map { $0 + 1 } ?? min(from, projects.count)
        projects.insert(project, at: insertAt)
        save()
    }

    /// 重命名:留空还原成目录名(改名只动显示名,路径与绑定不变)
    func rename(_ projectID: UUID, to name: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        projects[index].name = trimmed.isEmpty
            ? (projects[index].path as NSString).lastPathComponent
            : trimmed
        save()
    }

    func setSpace(_ spaceID: UUID?, for projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].spaceID = spaceID
        save()
    }

    func setAccent(_ hex: String?, for projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].accentHex = hex
        save()
    }

    /// 窗口当前项目:聚焦标签显式绑定优先,否则聚焦会话 cwd 前缀匹配(与侧边栏点亮判据一致)
    func current(for manager: SessionManager) -> Project? {
        if let bound = manager.selectedTab?.projectPath {
            return projects.first { $0.path == bound }
        }
        guard let cwd = manager.selected?.workingDirectory else { return nil }
        return projects.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// 项目 accent 预设:一组深浅主题下都站得住的中等饱和色(Finder 标签的思路)
struct ProjectAccentPreset: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let all: [ProjectAccentPreset] = [
        .init(name: String(localized: "红"), hex: "#E5534B"),
        .init(name: String(localized: "橙"), hex: "#F0883E"),
        .init(name: String(localized: "金"), hex: "#D4A72C"),
        .init(name: String(localized: "绿"), hex: "#57AB5A"),
        .init(name: String(localized: "青"), hex: "#39C5CF"),
        .init(name: String(localized: "蓝"), hex: "#539BF5"),
        .init(name: String(localized: "紫"), hex: "#986EE2"),
        .init(name: String(localized: "粉"), hex: "#E275AD"),
    ]

    @MainActor private static var swatchCache: [String: NSImage] = [:]

    /// 菜单里的圆形色块图标
    @MainActor var swatchImage: NSImage {
        if let cached = Self.swatchCache[hex] { return cached }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(hex: hex).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        Self.swatchCache[hex] = image
        return image
    }
}
