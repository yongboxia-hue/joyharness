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
            StatusPill(text: String(localized: "已授权"), color: JoyTheme.green)
        } else {
            Button(String(localized: "前往授权")) { state.requestAccessibility() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var languagePending: Bool { state.language != state.launchLanguage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(String(localized: "设置"), subtitle: String(localized: "授权、启动方式、外观，以及手柄和更新的行为。"))

                JoySectionHeader(String(localized: "权限"))

                JoyCard {
                    InfoRow(
                        symbol: "keyboard.badge.ellipsis",
                        title: String(localized: "辅助功能授权"),
                        // Not "已授权。" -- the pill beside it already
                        // says that word. A row says one thing once.
                        detail: state.accessibilityGranted
                            ? String(localized: "JoyHarness 可以替你按键盘了。")
                            : String(localized: "授权之后，JoyHarness 才能替你按键盘。"),
                        tint: state.accessibilityGranted ? JoyTheme.green : JoyTheme.orange,
                        trailing: AnyView(accessibilityAction)
                    )
                    .animation(JoyMotion.stateChange, value: state.accessibilityGranted)
                }

                JoySectionHeader(String(localized: "偏好"))

                JoyCard {
                    VStack(spacing: 0) {
                        InfoRow(
                            symbol: "arrow.up.right.square",
                            title: String(localized: "登录时启动 JoyHarness"),
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
                                        Button(String(localized: "前往确认")) { state.openLoginItemsSettings() }
                                            .buttonStyle(SecondaryButtonStyle())
                                    } else {
                                        Toggle(String(localized: "登录时启动"), isOn: Binding(
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
                            title: String(localized: "外观"),
                            detail: String(localized: "修改后立即生效。"),
                            trailing: AnyView(
                                Picker(String(localized: "外观"), selection: Binding(
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
                            symbol: "globe",
                            title: String(localized: "语言"),
                            detail: languagePending
                                ? String(localized: "重新打开 JoyHarness 后生效。")
                                : String(localized: "默认跟随系统语言。"),
                            trailing: AnyView(
                                HStack(spacing: 10) {
                                    if languagePending {
                                        Button(String(localized: "重新打开")) { state.relaunch() }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .accessibilityIdentifier("language-relaunch")
                                    }
                                    Picker(String(localized: "语言"), selection: Binding(
                                        get: { state.language },
                                        set: { state.setLanguage($0) }
                                    )) {
                                        ForEach(AppLanguage.allCases) { language in
                                            Text(language.title).tag(language)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 238)
                                    .accessibilityIdentifier("language-picker")
                                }
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "moon.zzz",
                            title: String(localized: "手柄闲着的时候自动休眠"),
                            detail: state.idleSleepEnabled
                                ? String(localized: "放着不用 \(Int(state.idleSleepMinutes)) 分钟就自己睡，按一下手柄就醒。")
                                : String(localized: "手柄一直连着会耗电。开启后放着不用它会自己睡，按一下就醒。"),
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
                            title: String(localized: "自动检查更新"),
                            detail: updater.automaticallyChecks
                                ? String(localized: "每天检查一次。发现新版本会先问你，不会自己装。")
                                : String(localized: "关闭后不会再检查，需要你自己留意新版本。"),
                            tint: .secondary,
                            trailing: AnyView(
                                HStack(spacing: 10) {
                                    Button(String(localized: "检查")) { updater.checkForUpdates() }
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
                    .animation(JoyMotion.stateChange, value: state.language)
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}
