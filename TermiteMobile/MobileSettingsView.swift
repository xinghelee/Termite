import SwiftUI

/// 设置:终端偏好 + Mac 管理 + 关于
struct MobileSettingsView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let client: RemoteClient

    @AppStorage(MobileSettingsKeys.fontSize) private var fontSize = MobileSettingsKeys.defaultFontSize
    @AppStorage(MobileSettingsKeys.keepAwake) private var keepAwake = true
    @AppStorage(MobileSettingsKeys.bellHaptics) private var bellHaptics = true

    @State private var renaming: SavedMac?
    @State private var renameText = ""

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return short
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("终端") {
                    Stepper(value: $fontSize, in: MobileSettingsKeys.fontSizeRange, step: 1) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    Toggle("终端页保持屏幕常亮", isOn: $keepAwake)
                    Toggle("响铃触感", isOn: $bellHaptics)
                }

                Section("我的 Mac") {
                    ForEach(store.macs) { mac in
                        Button {
                            store.selectedID = mac.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name)
                                        .foregroundStyle(.primary)
                                    Text("\(mac.host):\(String(mac.port))")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mac.id == store.selected?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("移除", role: .destructive) {
                                store.remove(mac)
                            }
                            Button("改名") {
                                renaming = mac
                                renameText = mac.name
                            }
                            .tint(.blue)
                        }
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("左滑可改名或移除;移除会一并删除本机保存的访问密钥。")
                }

                Section("关于") {
                    LabeledContent("版本", value: version)
                    LabeledContent("连接方式", value: String(localized: "局域网 / Tailscale 直连"))
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名", isPresented: .constant(renaming != nil)) {
                TextField("名称", text: $renameText)
                Button("好") {
                    if let mac = renaming { store.rename(mac, to: renameText) }
                    renaming = nil
                }
                Button("取消", role: .cancel) { renaming = nil }
            }
        }
    }
}
