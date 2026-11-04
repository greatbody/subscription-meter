import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var showPanel: () -> Void = {}
    var onSiliconFlowLogin: () -> Void = {}

    @State private var selectedTab: SettingsTab = .display
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    private enum SettingsTab: String, CaseIterable {
        case display = "显示", services = "服务", balance = "余额"
        var symbol: String {
            switch self {
            case .display: return "menubar.rectangle"
            case .services: return "square.stack.3d.up"
            case .balance: return "creditcard"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol).font(.system(size: 19, weight: .regular))
                            Text(tab.rawValue).font(.system(size: 11))
                        }
                        .frame(width: 72, height: 49)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selectedTab == tab ? Color.primary.opacity(0.09) : Color.clear))
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            Divider()
            Group {
                switch selectedTab {
                case .display: displaySettings
                case .services: providerSettings
                case .balance: balanceSettings
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 450)
    }

    private var displaySettings: some View {
        VStack(spacing: 0) {
            Form {
                Section("通用") {
                    Toggle("登录时启动", isOn: Binding(
                        get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                        set: { setLaunchAtLogin($0) }
                    ))
                    if loginItemStatus == .requiresApproval {
                        Text("请在系统设置的登录项中允许 Subscription Meter。")
                            .font(.callout).foregroundColor(.secondary)
                        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if let loginItemError {
                        Text(loginItemError).font(.callout).foregroundColor(.red)
                    }
                }
                Section("菜单栏") {
                    Picker("订阅名称", selection: $settings.useProviderIcons) {
                        Text("隐藏").tag(true)
                        Text("显示").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    LabeledContent("名称宽度") {
                        HStack(spacing: 12) {
                            Slider(value: $settings.nameWidth, in: 40...180, step: 1)
                            Text("\(Int(settings.nameWidth)) pt").monospacedDigit().frame(width: 55, alignment: .trailing)
                        }
                        .frame(maxWidth: 310)
                        .disabled(settings.useProviderIcons)
                    }
                    LabeledContent("名称滚动速度") {
                        HStack(spacing: 12) {
                            Slider(value: $settings.scrollSpeed, in: 4...40, step: 1)
                            Text("\(Int(settings.scrollSpeed)) pt/s").monospacedDigit().frame(width: 55, alignment: .trailing)
                        }
                        .frame(maxWidth: 310)
                        .disabled(settings.useProviderIcons)
                    }
                    LabeledContent("用量切换间隔") {
                        HStack(spacing: 12) {
                            Slider(value: $settings.rotationInterval, in: 3...30, step: 1)
                            Text("\(Int(settings.rotationInterval)) 秒").monospacedDigit().frame(width: 55, alignment: .trailing)
                        }
                        .frame(maxWidth: 310)
                    }
                }
                Section("数据") {
                    Picker("自动刷新", selection: $settings.refreshInterval) {
                        Text("每分钟").tag(60.0)
                        Text("每 5 分钟").tag(300.0)
                        Text("每 15 分钟").tag(900.0)
                        Text("每小时").tag(3600.0)
                    }
                    .frame(width: 180)
                }
            }
            .formStyle(.grouped)
            .onAppear { loginItemStatus = SMAppService.mainApp.status }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginItemStatus = SMAppService.mainApp.status
            }

            Divider()
            HStack {
                Spacer()
                Button("打开用量面板", action: showPanel)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = "无法更新登录项：\(error.localizedDescription)"
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    private var providerSettings: some View {
        Form {
            Section("显示的服务") {
                Toggle("GitHub Copilot", isOn: $settings.githubEnabled)
                Toggle("ChatGPT / Codex", isOn: $settings.chatGPTEnabled)
                Toggle("Anthropic / Claude", isOn: $settings.anthropicEnabled)
                Toggle("DeepSeek", isOn: $settings.deepSeekEnabled)
                Toggle("SiliconFlow", isOn: $settings.siliconFlowEnabled)
            }
            Section("账户连接") {
                Text("使用本机命令行工具当前登录的账户。请先安装对应工具，再在终端登录。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                loginRow("GitHub Copilot", command: "gh auth login")
                loginRow("ChatGPT / Codex", command: "codex login")
                loginRow("Anthropic / Claude", command: "claude")
            }
            Section("SiliconFlow 账户") {
                Text("在应用内登录窗口中由你自己登录。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("登录或重新登录 SiliconFlow", action: onSiliconFlowLogin)
            }
        }
        .formStyle(.grouped)
    }

    private var balanceSettings: some View {
        Form {
            Section("DeepSeek 圆环参考容量") {
                LabeledContent("参考容量") {
                    TextField("", text: $settings.deepSeekCapacity, prompt: Text("未设置"))
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                }
                if !settings.deepSeekCapacity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   AppSettings.parseCapacity(settings.deepSeekCapacity) == nil {
                    Text("请输入大于零的数字。")
                        .font(.callout).foregroundColor(.red)
                }
                Text("参考容量是纯数字，统一用于各项余额，不做汇率转换；留空时只显示余额状态。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("SiliconFlow 圆环参考容量") {
                LabeledContent("参考容量") {
                    TextField("", text: $settings.siliconFlowCapacity, prompt: Text("未设置"))
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                }
                if !settings.siliconFlowCapacity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   AppSettings.parseCapacity(settings.siliconFlowCapacity) == nil {
                    Text("请输入大于零的数字。")
                        .font(.callout).foregroundColor(.red)
                }
                Text("留空时只显示余额状态；参考容量仅用于 SiliconFlow。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("DeepSeek 余额提醒") {
                Text("余额低于设置的金额时显示橙色；留空表示不提醒。币种分别设置，不会合并计算。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                thresholdRow("人民币 CNY", value: $settings.deepSeekThresholdCNY)
                thresholdRow("美元 USD", value: $settings.deepSeekThresholdUSD)
            }
            Section("账户连接") {
                Text("使用 ~/.env 中的 DeepSeek 凭据查询余额，应用不会显示或复制凭据。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func thresholdRow(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                TextField("", text: value, prompt: Text("不提醒")).textFieldStyle(.roundedBorder).frame(width: 130)
            }
            if !value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               AppSettings.parseThreshold(value.wrappedValue) == nil {
                Text("请输入非负金额，最多两位小数。")
                    .font(.callout).foregroundColor(.red)
            }
        }
    }

    private func loginRow(_ name: String, command: String) -> some View {
        LabeledContent(name) {
            HStack(spacing: 12) {
                Text(command).font(.system(.callout, design: .monospaced)).foregroundColor(.secondary)
                Button("复制命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
    }
}
