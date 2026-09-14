import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var updater: UpdateManager

    @ViewBuilder
    private var accessibilityAction: some View {
        if state.accessibilityGranted {
            StatusPill(text: "已授权", color: JoyTheme.green)
        } else {
            Button("前往授权") { state.requestAccessibility() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle("关于", subtitle: "授权、偏好和支持。")

                JoyCard {
                    HStack(alignment: .top, spacing: 20) {
                        if let icon = state.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 94, height: 94)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            StatusPill(text: versionLabel, color: JoyTheme.blue)
                            Text("JoyHarness")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                            Text("把 Joy-Con 变成快捷键控制器")
                                .font(.system(size: 15, weight: .semibold))
                            Text("将 Joy-Con 按键映射为 macOS 快捷键，并按你的工作方式自由配置。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("偏好")
                    .font(.system(size: 15, weight: .semibold))

                JoyCard {
                    VStack(spacing: 0) {
                        InfoRow(
                            symbol: "arrow.up.right.square",
                            title: "登录时启动 JoyHarness",
                            detail: state.launchAtLoginDetail,
                            trailing: AnyView(
                                HStack(spacing: 10) {
                                    if state.launchAtLoginRequiresApproval {
                                        Button("前往确认") { state.openLoginItemsSettings() }
                                            .buttonStyle(SecondaryButtonStyle())
                                    } else {
                                        StatusPill(
                                            text: state.launchAtLoginStatus,
                                            color: state.launchAtLogin ? JoyTheme.green : .secondary
                                        )
                                    }
                                    Toggle("登录时启动", isOn: Binding(
                                        get: { state.launchAtLogin },
                                        set: { state.setLaunchAtLogin($0) }
                                    ))
                                    .labelsHidden()
                                    .disabled(state.isUpdatingLaunchAtLogin)
                                    .accessibilityIdentifier("launch-at-login-toggle")
                                }
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "circle.lefthalf.filled",
                            title: "外观",
                            detail: "修改后立即生效。",
                            trailing: AnyView(
                                Picker("外观", selection: Binding(
                                    get: { state.appearance },
                                    set: { state.setAppearance($0) }
                                )) {
                                    ForEach(AppAppearance.allCases) { appearance in
                                        Text(appearance.title).tag(appearance)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 238)
                                .accessibilityIdentifier("appearance-picker")
                            )
                        )
                    }
                    .animation(JoyMotion.stateChange, value: state.launchAtLogin)
                    .animation(JoyMotion.stateChange, value: state.launchAtLoginRequiresApproval)
                    .animation(JoyMotion.stateChange, value: state.appearance)
                }

                Text("系统")
                    .font(.system(size: 15, weight: .semibold))

                JoyCard {
                    VStack(spacing: 0) {
                        InfoRow(
                            symbol: "keyboard.badge.ellipsis",
                            title: "辅助功能授权",
                            detail: state.accessibilityGranted
                                ? "已授权。"
                                : "授权后 Joy-Con 才能发出快捷键。",
                            tint: state.accessibilityGranted ? JoyTheme.green : JoyTheme.orange,
                            trailing: AnyView(accessibilityAction)
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "moon.zzz",
                            title: "手柄空闲时自动休眠",
                            detail: state.idleSleepEnabled
                                ? "闲置 \(Int(state.idleSleepMinutes)) 分钟后手柄会断开并休眠，按任意键唤醒。"
                                : "读取按键需要手柄持续上报，长时间连接较为耗电。开启后闲置一段时间会让它休眠。",
                            tint: .secondary,
                            trailing: AnyView(
                                Toggle("", isOn: Binding(
                                    get: { state.idleSleepEnabled },
                                    set: { state.setIdleSleep(enabled: $0) }
                                ))
                                .labelsHidden()
                                .disabled(state.isSavingIdleSleep)
                                .accessibilityIdentifier("idle-sleep-toggle")
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "arrow.down.circle",
                            title: "自动检查更新",
                            detail: updater.automaticallyChecks
                                ? "每天检查一次。发现新版本会先问你，不会自己装。"
                                : "关闭后不会再检查，需要你自己留意新版本。",
                            tint: .secondary,
                            trailing: AnyView(
                                HStack(spacing: 10) {
                                    Button("检查") { updater.checkForUpdates() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("check-updates-now")
                                    Toggle("", isOn: $updater.automaticallyChecks)
                                        .labelsHidden()
                                        .accessibilityIdentifier("auto-update-toggle")
                                }
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        // Names the action, never the process behind it. The
                        // Python runtime is an implementation detail, and putting
                        // it on screen only asks the user to hold a concept they
                        // cannot act on; what they need is one button to press
                        // when the buttons stop responding.
                        InfoRow(
                            symbol: "arrow.clockwise",
                            title: "重启服务",
                            detail: state.serviceRunning
                                ? "按键没反应时，重启一次通常能恢复。"
                                : "当前没有运行，按键不会有反应。",
                            tint: state.serviceRunning ? .secondary : .red,
                            trailing: AnyView(
                                Button(state.isPerformingServiceAction ? "处理中…" : "重启") {
                                    state.restartService()
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(state.isPerformingServiceAction)
                            )
                        )
                    }
                    .animation(JoyMotion.stateChange, value: state.accessibilityGranted)
                    .animation(JoyMotion.stateChange, value: state.serviceRunning)
                }

                Text("支持")
                    .font(.system(size: 15, weight: .semibold))

                JoyCard {
                    VStack(spacing: 0) {
                        InfoRow(
                            symbol: "sparkles.rectangle.stack",
                            title: "首次使用引导",
                            detail: "重新走一遍授权、连接和按键测试。",
                            trailing: AnyView(
                                Button("重新查看") { state.showOnboarding() }
                                    .buttonStyle(SecondaryButtonStyle())
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "stethoscope",
                            title: "运行诊断",
                            detail: "在本地生成一份排查用的文件，不会上传。",
                            trailing: AnyView(
                                Button(state.isExportingDiagnostics ? "正在导出…" : "导出诊断包") { state.exportDiagnostics() }
                                    .buttonStyle(SecondaryButtonStyle())
                                    .disabled(state.isExportingDiagnostics)
                                    .accessibilityIdentifier("export-diagnostics")
                            )
                        )
                    }
                    .animation(JoyMotion.stateChange, value: state.isExportingDiagnostics)
                }

                if state.buildFlavor == "preview" {
                    Text("Preview 的外观和登录项只作用于 Preview 身份，不会替换正式 App 或改变正式 App 的设置。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .onAppear { state.refreshLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshLaunchAtLogin()
        }
    }

    /// Straight from the bundle the user is running. No hard-coded fallback
    /// version: one sat here reading 0.2.0 while the changelog said 0.1.0, and
    /// a wrong version number is worse than an admittedly missing one.
    private var versionLabel: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return "版本未知" }
        return state.buildFlavor == "preview" ? "版本 \(version) Preview" : "版本 \(version)"
    }
}
