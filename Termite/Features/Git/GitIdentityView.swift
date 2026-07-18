import SwiftUI

/// git 身份快捷编辑(工作/个人双身份场景):改 user.name / user.email,
/// 作用域可选「仅本仓库(--local)」或「全局(--global)」;可一键清除仓库级覆盖。
struct GitIdentityView: View {
    let repoRoot: String

    @State private var name = ""
    @State private var email = ""
    @State private var useGlobal = false
    @State private var hasLocalOverride = false
    @State private var savedFlash = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("提交身份", systemImage: "person.crop.circle")
                .font(.system(size: 12, weight: .semibold))

            TextField("用户名", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            TextField("邮箱", text: $email)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            Picker("作用域", selection: $useGlobal) {
                Text("仅本仓库").tag(false)
                Text("全局").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if hasLocalOverride {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("本仓库有身份覆盖")
                    Button("清除,回落到全局") {
                        Task {
                            await GitService.clearLocalIdentity(in: repoRoot)
                            await load()
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack {
                if savedFlash {
                    Label("已保存", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("保存") {
                    Task {
                        await GitService.setIdentity(
                            name: name.trimmingCharacters(in: .whitespaces),
                            email: email.trimmingCharacters(in: .whitespaces),
                            global: useGlobal,
                            in: repoRoot
                        )
                        await load()
                        savedFlash = true
                        try? await Task.sleep(for: .seconds(1.2))
                        savedFlash = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                    || email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .task { await load() }
    }

    private func load() async {
        let identity = await GitService.identity(in: repoRoot)
        name = identity.name
        email = identity.email
        hasLocalOverride = identity.hasLocal
    }
}
