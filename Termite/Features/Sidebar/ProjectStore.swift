import Foundation
import Observation
import SwiftUI

/// 侧边栏项目:一个常用工作目录
struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
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
        projects.append(Project(name: (standardized as NSString).lastPathComponent, path: standardized))
        save()
    }

    func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        projects.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
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
