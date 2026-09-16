import AppKit
import SwiftUI

/// Everything that is a choice, on one screen.
///
/// These rows used to sit under 关于, which made that page nine hundred points
/// tall and mixed three unrelated jobs: which app this is, what you have
/// chosen, and what to do when something is wrong. Preferences are the largest
/// of the three and the only one you come back to, so they get the page.
///
/// 辅助功能授权 is here rather than with the troubleshooting rows because it is
/// a switch the user throws once, and because every place that sends someone
/// to grant it now sends them here.
struct SettingsView: View {
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
                PageTitle("设置", subtitle: "授权、启动方式、外观，以及手柄和更新的行为。")

                JoySectionHeader("权限")

                JoyCard {
                    InfoRow(
                        symbol: "keyboard.badge.ellipsis",
                        title: "辅助功能授权",
                        // Not "已授权。" -- the pill beside it already
                        // says that word. A row says one thing once.
                        detail: state.accessibilityGranted
                            ? "JoyHarness 可以替你按键盘了。"
                            : "授权之后，JoyHarness 才能替你按键盘。",
                        tint: state.accessibilityGranted ? JoyTheme.green : JoyTheme.orange,
                        trailing: AnyView(accessibilityAction)
                    )
                    .animation(JoyMotion.stateChange, value: state.accessibilityGranted)
                }

                JoySectionHeader("偏好")

                JoyCard {
                    VStack(spacing: 0) {
                        InfoRow(
                            symbol: "arrow.up.right.square",
                            title: "登录时启动 JoyHarness",
                            detail: state.launchAtLoginDetail,
                            trailing: AnyView(
                                // One control, and nothing beside it saying
                                // what the control already says. While macOS
                                // is waiting for the user to approve the login
                                // item, the switch cannot do anything, so the
                                // escape hatch takes its place rather than
                                // sitting next to a dead switch.
                                HStack(spacing: 10) {
                                    if state.launchAtLoginRequiresApproval {
                                        Button("前往确认") { state.openLoginItemsSettings() }
                                            .buttonStyle(SecondaryButtonStyle())
                                    } else {
                                        Toggle("登录时启动", isOn: Binding(
                                            get: { state.launchAtLogin },
                                            set: { state.setLaunchAtLogin($0) }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .disabled(state.isUpdatingLaunchAtLogin)
                                        .accessibilityIdentifier("launch-at-login-toggle")
                                    }
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
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "moon.zzz",
                            title: "手柄闲着的时候自动休眠",
                            detail: state.idleSleepEnabled
                                ? "放着不用 \(Int(state.idleSleepMinutes)) 分钟就自己睡，按一下手柄就醒。"
                                : "手柄一直连着会耗电。开启后放着不用它会自己睡，按一下就醒。",
                            tint: .secondary,
                            trailing: AnyView(
                                Toggle("", isOn: Binding(
                                    get: { state.idleSleepEnabled },
                                    set: { state.setIdleSleep(enabled: $0) }
                                ))
                                .toggleStyle(.switch)
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
                                        .buttonStyle(SecondaryButtonStyle())
                                        .accessibilityIdentifier("check-updates-now")
                                    Toggle("", isOn: $updater.automaticallyChecks)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .accessibilityIdentifier("auto-update-toggle")
                                }
                            )
                        )
                    }
                    .animation(JoyMotion.stateChange, value: state.launchAtLogin)
                    .animation(JoyMotion.stateChange, value: state.launchAtLoginRequiresApproval)
                    .animation(JoyMotion.stateChange, value: state.appearance)
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}
