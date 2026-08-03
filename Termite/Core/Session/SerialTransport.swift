import AppKit
import Foundation

/// 串口会话支持(v1,issue #6):/dev/cu.* 设备 + 波特率,字节双向接进终端视图。
/// 无 shell、无保活——app 退出即断开;纯串口标签不进会话快照
enum SerialPort {
    /// 可用设备:只列 cu.*(callout 设备;tty.* 是等 DCD 的 dial-in,直连会卡在 open)
    static func devices() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return all.filter { $0.hasPrefix("cu.") }
            .map { "/dev/" + $0 }
            .sorted()
    }

    static let baudPresets = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

    /// 打开并配置为 8N1 raw 模式;失败(占用/无权限)返回 nil
    static func open(path: String, baud: Int) -> Int32? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var tio = termios()
        guard tcgetattr(fd, &tio) == 0 else { Darwin.close(fd); return nil }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
        tio.c_cflag |= tcflag_t(CS8)
        cfsetspeed(&tio, speed_t(baud))
        guard tcsetattr(fd, TCSANOW, &tio) == 0 else { Darwin.close(fd); return nil }
        // 清掉线上残留的陈旧字节,新会话从干净状态开始
        tcflush(fd, TCIOFLUSH)
        return fd
    }
}

/// 「新建串口会话」弹框:设备下拉 + 波特率下拉(默认 115200)
@MainActor
enum SerialPrompt {
    static func present() {
        let alert = NSAlert()
        alert.messageText = String(localized: "新建串口会话")
        let devices = SerialPort.devices()
        guard !devices.isEmpty else {
            alert.informativeText = String(localized: "没有找到串口设备(/dev/cu.*)。插上 USB 转串口线后再试。")
            alert.addButton(withTitle: String(localized: "好"))
            alert.runModal()
            return
        }
        alert.informativeText = String(localized: "选择设备与波特率(8N1)。串口会话不参与保活与恢复。")
        let devicePop = NSPopUpButton(frame: NSRect(x: 0, y: 62, width: 300, height: 26))
        devicePop.addItems(withTitles: devices)
        let baudPop = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 300, height: 26))
        baudPop.addItems(withTitles: SerialPort.baudPresets.map(String.init))
        baudPop.selectItem(withTitle: "115200")
        // 串口终端没有本地回显,键入靠对端回显;哑设备场景勾这个才看得见输入
        let echoCheck = NSButton(checkboxWithTitle: String(localized: "本地回显(设备不回显键入时勾选)"), target: nil, action: nil)
        echoCheck.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 92))
        container.addSubview(devicePop)
        container.addSubview(baudPop)
        container.addSubview(echoCheck)
        alert.accessoryView = container
        alert.addButton(withTitle: String(localized: "连接"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let device = devicePop.titleOfSelectedItem,
              let baud = Int(baudPop.titleOfSelectedItem ?? "") else { return }
        SessionManager.shared.newSerialTab(device: device, baud: baud, localEcho: echoCheck.state == .on)
    }
}
