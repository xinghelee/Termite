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
    /// 会话保活:守护进程里的会话 ID + 已消费输出偏移(重启后无缝接回;工作区模板不用)
    var ptyID: UUID?
    var ptyOffset: UInt64?

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

    /// 树上全部保活会话 ID(启动时区分「待接回」与「孤儿」)
    var allPtyIDs: [UUID] {
        var ids: [UUID] = []
        if let ptyID { ids.append(ptyID) }
        ids += (first?.allPtyIDs ?? []) + (second?.allPtyIDs ?? [])
        return ids
    }
}

/// 恢复用的单个标签状态:布局树 + 焦点/最大化 pane(按叶子在树中的 DFS 序号记录,
/// 重建时树形状一致,序号即可映射回会话)
struct SavedTabState: Codable {
    var root: WorkspaceNode
    var focusedLeafIndex: Int?
    var maximizedLeafIndex: Int?

    init(root: WorkspaceNode, focusedLeafIndex: Int? = nil, maximizedLeafIndex: Int? = nil) {
        self.root = root
        self.focusedLeafIndex = focusedLeafIndex
        self.maximizedLeafIndex = maximizedLeafIndex
    }
}

/// 单个窗口的恢复状态
struct SavedWindowState: Codable {
    var tabs: [SavedTabState]
    var selectedIndex: Int?
    /// NSStringFromRect 的窗口 frame(屏幕坐标)
    var frame: String?
}

/// 整个 App 的会话恢复状态:按窗口分组。
/// 旧版(v1)是所有窗口标签压平的 {tabs, selectedIndex},解码时迁移为单窗口。
struct SavedAppState: Codable {
    var windows: [SavedWindowState]
    var activeWindowIndex: Int?

    init(windows: [SavedWindowState], activeWindowIndex: Int?) {
        self.windows = windows
        self.activeWindowIndex = activeWindowIndex
    }

    private enum CodingKeys: String, CodingKey {
        case windows, activeWindowIndex
        case tabs, selectedIndex // v1
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let windows = try container.decodeIfPresent([SavedWindowState].self, forKey: .windows) {
            self.windows = windows
            self.activeWindowIndex = try container.decodeIfPresent(Int.self, forKey: .activeWindowIndex)
            return
        }
        let legacyTabs = try container.decodeIfPresent([WorkspaceNode].self, forKey: .tabs) ?? []
        let legacySelected = try container.decodeIfPresent(Int.self, forKey: .selectedIndex)
        windows = legacyTabs.isEmpty ? [] : [SavedWindowState(
            tabs: legacyTabs.map { SavedTabState(root: $0) },
            selectedIndex: legacySelected,
            frame: nil
        )]
        activeWindowIndex = windows.isEmpty ? nil : 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(activeWindowIndex, forKey: .activeWindowIndex)
    }

    /// 全部窗口的保活会话 ID(启动时区分「待接回」与「孤儿」)
    var allPtyIDs: [UUID] {
        windows.flatMap { $0.tabs.flatMap(\.root.allPtyIDs) }
    }
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
