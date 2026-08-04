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

    /// 最近一次切换的进场方向(工作区名的水平推入动画):向后切=新内容从右侧推入
    private(set) var slideEdge: Edge = .trailing

    /// 当前工作区在列表中的位置(侧边栏分页 strip 的定位基准)
    var selectedIndex: Int {
        spaces.firstIndex { $0.id == selectedID } ?? 0
    }

    func select(_ id: UUID) {
        if let from = spaces.firstIndex(where: { $0.id == selectedID }),
           let to = spaces.firstIndex(where: { $0.id == id }) {
            slideEdge = to >= from ? .trailing : .leading
        }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedKey)
        notifyWorkspaceChange()
    }

    // MARK: - 跟手横扫

    /// 切换进度 −1…1(负=下一个工作区正在进场,正=上一个)。
    /// 侧边栏据此做 shared-axis 转场:内容只平移几十点,靠透明度完成交接——
    /// 全宽平移一整个列表既沉又要在动画中途构建新页面,那是卡顿的来源
    private(set) var dragProgress: CGFloat = 0

    /// 一次切换需要的手指行程:半个侧边栏宽,再给个下限免得窄侧边栏太灵敏
    private func swipeSpan(width: CGFloat) -> CGFloat {
        max(90, width * 0.5)
    }

    /// 手指移动:首尾之外的方向加阻尼(橡皮筋),让"到头了"有手感而不是硬停
    func dragChanged(_ translation: CGFloat, width: CGFloat) {
        guard spaces.count > 1 else { return }
        let index = selectedIndex
        var progress = translation / swipeSpan(width: width)
        if (progress > 0 && index == 0) || (progress < 0 && index == spaces.count - 1) {
            progress *= 0.25
        }
        dragProgress = max(-1, min(1, progress))
    }

    /// 松手:按手指速度把进度投影出去,过半就完成切换,否则退回。
    /// 初速度喂给 interpolatingSpring —— iOS 那种"甩出去"的惯性来自这里,
    /// 而不是来自更长的位移距离
    func dragEnded(velocity: CGFloat, width: CGFloat) {
        guard dragProgress != 0 else { return }
        let span = swipeSpan(width: width)
        // velocity 是 pt/s,换算成"进度/秒"才能和 dragProgress 同一量纲
        let progressVelocity = velocity / span
        let projected = dragProgress + progressVelocity * 0.13
        let delta = dragProgress > 0 ? -1 : 1
        let canMove = spaces.indices.contains(selectedIndex + delta)
        let committed = abs(projected) > 0.5 && canMove

        let target: CGFloat = committed ? (dragProgress > 0 ? 1 : -1) : 0
        let distance = target - dragProgress
        // 初速度按动画总行程归一化;行程趋零时归一化会炸,夹住
        let initialVelocity = distance == 0 ? 0 : max(-24, min(24, progressVelocity / distance))
        let animation = Animation.interpolatingSpring(duration: 0.32, bounce: 0.08,
                                                      initialVelocity: initialVelocity)

        guard committed else {
            withAnimation(animation) { dragProgress = 0 }
            return
        }
        // 进度推到 ±1 时,进场页已经严丝合缝落在 offset 0 / 不透明,
        // 此刻换选中并把进度归零,画面前后完全一致,不闪
        let target2 = spaces[selectedIndex + delta].id
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            dragProgress = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.select(target2)
                self.dragProgress = 0
            }
        }
    }

    /// 手势被打断(切窗口等):无条件退回
    func dragCancelled() {
        guard dragProgress != 0 else { return }
        withAnimation(.interpolatingSpring(duration: 0.28, bounce: 0.08)) { dragProgress = 0 }
    }

    /// 工作区切换/删除后让各窗口重选标签(不在本工作区的标签藏起来,空工作区回欢迎面板)
    private func notifyWorkspaceChange() {
        for manager in SessionManagerRegistry.shared.managers {
            manager.workspaceDidChange()
        }
    }

    /// 相邻切换(触控板横扫 / ⌃⌥←→):到首尾即止,不循环——
    /// 侧边栏已改成横向分页 strip,循环意味着一次切换整条横向飞过所有工作区
    func selectAdjacent(_ delta: Int) {
        guard spaces.count > 1 else { return }
        let target = selectedIndex + delta
        guard spaces.indices.contains(target) else { return }
        select(spaces[target].id)
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
