import Foundation
import Observation

/// 工作区模板:一整套「标签 + 分屏树(含比例与各 pane 工作目录)」的快照
struct Workspace: Identifiable, Codable {
    var id = UUID()
    var name: String
    var tabs: [WorkspaceNode]

    var paneCount: Int {
        tabs.reduce(0) { $0 + $1.leafCount }
    }
}

/// 布局节点:cwd 非空 = 叶子;axis 非空 = 分支(h/v + ratio + 两子树)
final class WorkspaceNode: Codable {
    var cwd: String?
    var axis: String?
    var ratio: Double?
    var first: WorkspaceNode?
    var second: WorkspaceNode?
    /// 会话恢复:该叶子的 scrollback 快照文件名(restore 目录下;工作区模板不用)
    var scrollbackFile: String?

    init(cwd: String?) {
        self.cwd = cwd
    }

    init(axis: String, ratio: Double, first: WorkspaceNode, second: WorkspaceNode) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }

    var isLeaf: Bool { axis == nil }

    var leafCount: Int {
        if isLeaf { return 1 }
        return (first?.leafCount ?? 0) + (second?.leafCount ?? 0)
    }

    /// 第一个叶子的 cwd(建标签时的起始目录)
    var firstLeafCwd: String? {
        if isLeaf { return cwd }
        return first?.firstLeafCwd ?? second?.firstLeafCwd
    }

    /// 第一个叶子节点(取 scrollback 引用用)
    var firstLeafNode: WorkspaceNode {
        if isLeaf { return self }
        return first?.firstLeafNode ?? second?.firstLeafNode ?? self
    }
}

/// 整个 App 的会话恢复状态(所有窗口的标签合并)
struct SavedAppState: Codable {
    var tabs: [WorkspaceNode]
    var selectedIndex: Int?
}

/// 工作区列表(侧边栏「工作区」区块数据源):持久化在 UserDefaults(JSON)
@MainActor
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    /// 用户决定不要工作区功能,入口永久隐藏(会话恢复复用其布局重建代码,保留)
    static let isEnabled = false

    private(set) var workspaces: [Workspace] = []

    private static let key = "sidebar.workspaces"

    init() {
        load()
    }

    func add(name: String, tabs: [WorkspaceNode]) {
        workspaces.append(Workspace(name: name, tabs: tabs))
        save()
    }

    func overwrite(_ workspace: Workspace, tabs: [WorkspaceNode]) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].tabs = tabs
        save()
    }

    func remove(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Workspace].self, from: data) else { return }
        workspaces = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
