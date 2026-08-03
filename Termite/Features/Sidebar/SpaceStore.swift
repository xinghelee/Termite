import AppKit
import Foundation
import Observation
import SwiftUI

/// Arc 式工作区:项目的分组容器,严格归属制——每个项目属于一个工作区,
/// 新建的工作区是一张白纸。历史项目(spaceID 为 nil)与所属工作区已删除的
/// 项目自动归入第一个工作区(项目永远不会凭空消失);
/// 没有任何工作区时侧边栏保持扁平列表,功能零打扰
struct SidebarSpace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// 曾经的工作区专属色(小点已改单色,字段保留以兼容旧存档)
    var accentHex: String?
}

/// 工作区列表 + 当前选中(全局,跨窗口一致):持久化在 UserDefaults
@MainActor
@Observable
final class SpaceStore {
    static let shared = SpaceStore()

    private(set) var spaces: [SidebarSpace] = []
    private(set) var selectedID: UUID?

    private static let listKey = "sidebar.spaces"
    private static let selectedKey = "sidebar.selectedSpace"

    init() {
        load()
    }

    var selected: SidebarSpace? {
        spaces.first { $0.id == selectedID } ?? spaces.first
    }

    /// 项目的有效归属:归属无效(nil / 工作区已删)回落到第一个工作区
    func effectiveSpaceID(of project: Project) -> UUID? {
        project.spaceID.flatMap { id in
            spaces.contains { $0.id == id } ? id : nil
        } ?? spaces.first?.id
    }

    /// 项目在当前工作区是否可见
    func isVisible(_ project: Project) -> Bool {
        guard let space = selected else { return true }
        return effectiveSpaceID(of: project) == space.id
    }

    /// 最近一次切换的进场方向(侧边栏水平推入动画):向后切=新内容从右侧推入
    private(set) var slideEdge: Edge = .trailing

    func select(_ id: UUID) {
        if let from = spaces.firstIndex(where: { $0.id == selectedID }),
           let to = spaces.firstIndex(where: { $0.id == id }) {
            slideEdge = to >= from ? .trailing : .leading
        }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedKey)
        notifyWorkspaceChange()
    }

    /// 工作区切换/删除后让各窗口重选标签(不在本工作区的标签藏起来,空工作区回欢迎面板)
    private func notifyWorkspaceChange() {
        for manager in SessionManagerRegistry.shared.managers {
            manager.workspaceDidChange()
        }
    }

    /// 相邻切换(触控板横扫 / ⌃⌥←→):循环滚动
    func selectAdjacent(_ delta: Int) {
        guard spaces.count > 1, let current = selected,
              let index = spaces.firstIndex(of: current) else { return }
        select(spaces[(index + delta + spaces.count) % spaces.count].id)
    }

    @discardableResult
    func add(name: String) -> SidebarSpace {
        let space = SidebarSpace(name: name)
        spaces.append(space)
        save()
        select(space.id)
        return space
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
        save()
    }

    /// 删除工作区:它的项目按「归属无效→第一个工作区」规则自动回流,不动任何终端
    func remove(_ id: UUID) {
        spaces.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = spaces.first?.id
        }
        // 选中态一并落盘,避免残留已删 id(重启后指向不存在的工作区)
        if let selectedID {
            UserDefaults.standard.set(selectedID.uuidString, forKey: Self.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
        save()
        notifyWorkspaceChange()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let decoded = try? JSONDecoder().decode([SidebarSpace].self, from: data) {
            spaces = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: raw), spaces.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = spaces.first?.id
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        UserDefaults.standard.set(data, forKey: Self.listKey)
    }
}
