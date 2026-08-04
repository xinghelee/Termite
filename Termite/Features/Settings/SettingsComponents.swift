import SwiftUI

/// 设置页的排版件:分组小标题 + 圆角卡片,卡片里每行左边标题(可带副标题)、右边控件。
/// 颜色全部取自当前主题,与 pane、状态栏同一套材质。

/// 一整页设置:纵向滚动 + 分组间距
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 系统「始终显示滚动条」下,右侧那条亮灰滚动条在深色主题里刺眼;
        // 设置页内容不长,靠滚轮/触控板足够
        .scrollIndicators(.hidden)
    }
}

/// 分组标题:小字距、次要色,只做视觉分隔不抢内容
private struct SettingsGroupTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
    }
}

/// 一组设置项:标题 + 卡片,行与行之间自动补分隔线
struct SettingsGroup: View {
    let title: LocalizedStringKey
    private let rows: [AnyView]

    @State private var themeStore = ThemeStore.shared

    init(_ title: LocalizedStringKey, @SettingsRowsBuilder rows: () -> [AnyView]) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroupTitle(title: title)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle()
                            .fill(themeStore.current.borderColor)
                            .frame(height: 1)
                            .padding(.leading, 16)
                    }
                    rows[index]
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeStore.current.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(themeStore.current.borderColor, lineWidth: 1)
            )
        }
    }
}

/// 自由内容的分组(主题色卡这类不按「行」排的内容)
struct SettingsPanel<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    @State private var themeStore = ThemeStore.shared

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroupTitle(title: title)
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(themeStore.current.elevatedBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(themeStore.current.borderColor, lineWidth: 1)
                )
        }
    }
}

/// 卡片内的一行:标题(可带副标题)+ 右侧控件
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// 开关行(设置里最常见的一行,免去每处写 labelsHidden)
struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// 卡片下方的补充说明(长解释不塞进行里,免得行高失控)
struct SettingsFootnote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, -6)
    }
}

/// 分段选择:系统 segmented 的选中色跟随系统强调色,与主题不搭,自绘一版
struct SettingsSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        var id: Value { value }

        init(_ value: Value, _ title: LocalizedStringKey) {
            self.value = value
            self.title = title
        }
    }

    @Binding var selection: Value
    let options: [Option]

    @State private var themeStore = ThemeStore.shared

    private var theme: TerminalTheme { themeStore.current }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected
                            ? AnyShapeStyle(Color(nsColor: theme.backgroundNSColor))
                            : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isSelected ? theme.accentColor : .clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.chromeBackground))
        .overlay(Capsule().strokeBorder(theme.borderColor, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

/// SettingsGroup 的行收集器:让调用处照常一行一行写(含 if 分支),内部按序号补分隔线
@resultBuilder
enum SettingsRowsBuilder {
    static func buildExpression<V: View>(_ view: V) -> [AnyView] { [AnyView(view)] }
    static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [AnyView]?) -> [AnyView] { part ?? [] }
    static func buildEither(first: [AnyView]) -> [AnyView] { first }
    static func buildEither(second: [AnyView]) -> [AnyView] { second }
    static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}
