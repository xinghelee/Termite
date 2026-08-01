import AppKit

/// 把 file(:line(:col)) 送进编辑器:设置里选了 App 就用它,否则探测常见编辑器,兜底系统默认。
/// VS Code 系 / Zed 走 URL scheme 直达行号,Xcode 走 xed --line。
enum EditorLauncher {

    static var appURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: SettingsKeys.editorAppPath),
              !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var displayName: String {
        if let url = appURL { return FileManager.default.displayName(atPath: url.path) }
        if let url = detectedURL {
            return FileManager.default.displayName(atPath: url.path) + String(localized: "(自动检测)")
        }
        return String(localized: "系统默认")
    }

    /// 探测顺序:VS Code → Cursor → VSCodium → Zed → Sublime → Xcode
    private static let knownBundleIDs = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.vscodium",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.apple.dt.Xcode",
    ]

    private static var detectedURL: URL? {
        for id in knownBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// 支持 scheme://file/绝对路径:行:列 直达行号的编辑器
    private static func scheme(for bundleID: String) -> String? {
        switch bundleID {
        case "com.microsoft.VSCode": "vscode"
        case "com.microsoft.VSCodeInsiders": "vscode-insiders"
        case "com.vscodium": "vscodium"
        case "com.todesktop.230313mzl4w4u92": "cursor"
        case "dev.zed.Zed": "zed"
        default: nil
        }
    }

    static func open(path: String, line: Int?, column: Int?) {
        guard let app = appURL ?? detectedURL else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let bundleID = Bundle(url: app)?.bundleIdentifier ?? ""
        if let line, let scheme = scheme(for: bundleID),
           let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "\(scheme)://file\(encoded):\(line)" + (column.map { ":\($0)" } ?? "")) {
            NSWorkspace.shared.open(url)
            return
        }
        if let line, bundleID == "com.apple.dt.Xcode" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = ["--line", String(line), path]
            if (try? process.run()) != nil { return }
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @MainActor
    static func chooseApp(onPicked: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "选择用来打开 file:line 的编辑器")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPicked(url.path)
        }
    }
}
