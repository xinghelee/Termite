import SwiftUI

/// 模拟器 tab:列出 Mac 上的模拟器,未启动的一键启动,启动了的点进去看画面并操作。
///
/// 之所以要这一屏:镜像必须有个跑着的设备,而人在外面时没法去 Mac 上点启动。
struct SimulatorTabView: View {
    let client: MirrorClient

    @Environment(ConnectionStore.self) private var store
    @Environment(\.termiteTheme) private var theme
    @State private var opened: MirrorClient.Device?
    @State private var busy: Set<String> = []

    private var grouped: [(runtime: String, devices: [MirrorClient.Device])] {
        let groups = Dictionary(grouping: client.devices) { $0.runtime.isEmpty ? "其它" : $0.runtime }
        return groups.keys.sorted(by: >).map { (runtime: $0, devices: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !client.available {
                    ContentUnavailableView {
                        Label("不可用", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Mac 上找不到 Xcode 的模拟器接口")
                    }
                } else if client.devices.isEmpty {
                    ContentUnavailableView {
                        Label("没有模拟器", systemImage: "iphone.slash")
                    } description: {
                        Text("下拉刷新,或在 Mac 的 Xcode 里先建一个")
                    }
                } else {
                    list
                }
            }
            .termiteScreen(theme)
            .navigationTitle("模拟器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .refreshable { client.requestDevices() }
            .navigationDestination(item: $opened) { device in
                SimulatorScreen(client: client, device: device)
            }
        }
        .onAppear {
            if let mac = store.selected, let endpoint = store.endpoint(for: mac) {
                client.connect(endpoint)
            }
            client.requestDevices()
        }
        .onChange(of: client.devices) { _, devices in
            // 启动完成后把 busy 标记清掉
            for device in devices where device.isBooted { busy.remove(device.id) }
        }
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.runtime) { group in
                Section {
                    ForEach(group.devices) { device in
                        row(device).termiteRow(theme)
                    }
                } header: {
                    // 自定 header:系统默认那套大写+上下留白在小屏上顶掉一屏
                    Text(group.runtime)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .textCase(nil)
                        .padding(.bottom, 2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
    }

    private func row(_ device: MirrorClient.Device) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.name.localizedCaseInsensitiveContains("ipad")
                  ? "ipad" : "iphone")
                .font(.system(size: 15))
                .foregroundStyle(device.isBooted ? theme.accent : theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 15, weight: .medium))
                Text(device.isBooted ? "运行中" : "已关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(device.isBooted ? theme.accent : theme.secondaryText)
            }
            Spacer()
            if busy.contains(device.id) {
                ProgressView().controlSize(.small)
            } else if device.isBooted {
                Button("查看") { opened = device }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Menu {
                    Button("关闭模拟器", systemImage: "power", role: .destructive) {
                        busy.insert(device.id)
                        client.shutdown(device.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Button("启动") {
                    busy.insert(device.id)
                    client.boot(device.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 全屏看 + 操作某台模拟器。附着在这里做,离开即停 —— 不看时不占 Mac 的编码开销
struct SimulatorScreen: View {
    let client: MirrorClient
    let device: MirrorClient.Device

    var body: some View {
        SimulatorFullScreenContent(client: client)
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { client.attach(device.id, maxWidth: 720, fps: 20) }
            .onDisappear { client.detach() }
    }
}
