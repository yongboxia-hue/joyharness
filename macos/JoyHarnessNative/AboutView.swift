import AppKit
import SwiftUI

/// Which app this is, and what to do when it is not behaving.
///
/// It used to carry the preferences as well, which made it nine hundred points
/// tall in a seven-hundred-and-eighty point window and mixed three unrelated
/// jobs on one page. The choices moved to 设置; what is left is identity and
/// the two things you reach for when something is wrong.
struct AboutView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(String(localized: "关于"), subtitle: String(localized: "版本信息，以及出问题时的排查入口。"))

                JoyCard {
                    HStack(spacing: 20) {
                        if let icon = state.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 94, height: 94)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("JoyHarness")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                            Text(String(localized: "把 Joy-Con 变成快捷键控制器"))
                                .font(.system(size: 15, weight: .semibold))
                            Text(versionLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(JoyTheme.detail)
                        }
                    }
                }

                JoySectionHeader(String(localized: "出问题时"))

                JoyCard {
                    VStack(spacing: 0) {
                        // Names the action, never the process behind it. The
                        // Python runtime is an implementation detail, and putting
                        // it on screen only asks the user to hold a concept they
                        // cannot act on; what they need is one button to press
                        // when the buttons stop responding.
                        InfoRow(
                            symbol: "arrow.clockwise",
                            title: String(localized: "重启服务"),
                            detail: state.serviceRunning
                                ? String(localized: "手柄按了没反应时，重启一次通常就好了。")
                                : String(localized: "现在没在运行，按手柄不会有反应。"),
                            tint: state.serviceRunning ? .secondary : .red,
                            trailing: AnyView(
                                Button {
                                    state.restartService()
                                } label: {
                                    SteadyTitle(state.isPerformingServiceAction ? String(localized: "处理中…") : String(localized: "重启"),
                                                of: [String(localized: "重启"), String(localized: "处理中…")])
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(state.isPerformingServiceAction)
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "sparkles.rectangle.stack",
                            title: String(localized: "首次使用引导"),
                            detail: String(localized: "从头走一遍：授权、连手柄、试按键。"),
                            trailing: AnyView(
                                Button(String(localized: "重新查看")) { state.showOnboarding() }
                                    .buttonStyle(SecondaryButtonStyle())
                            )
                        )
                        Divider().padding(.leading, 47).padding(.vertical, 12)
                        InfoRow(
                            symbol: "stethoscope",
                            title: String(localized: "运行诊断"),
                            detail: String(localized: "在本机生成一份排查用的文件，不会上传到任何地方。"),
                            trailing: AnyView(
                                Button { state.exportDiagnostics() } label: {
                                    SteadyTitle(state.isExportingDiagnostics ? String(localized: "正在导出…") : String(localized: "导出诊断包"),
                                                of: [String(localized: "导出诊断包"), String(localized: "正在导出…")])
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(state.isExportingDiagnostics)
                                .accessibilityIdentifier("export-diagnostics")
                            )
                        )
                    }
                    .animation(JoyMotion.stateChange, value: state.serviceRunning)
                    .animation(JoyMotion.stateChange, value: state.isExportingDiagnostics)
                }

                // The Python runtime started as VaderCheng's JoyHarness, and its
                // MIT license asks for the notice to travel with every copy. The
                // full text ships in Resources/LICENSE; this line is where a
                // person would look for it.
                HStack(spacing: 0) {
                    Text(String(localized: "基于开源项目 ")).foregroundStyle(JoyTheme.detail)
                    Link("VaderCheng/JoyHarness", destination: URL(string: "https://github.com/VaderCheng/JoyHarness")!)
                    Text(String(localized: "，MIT 许可。")).foregroundStyle(JoyTheme.detail)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 4)

                if state.buildFlavor == "preview" {
                    Text(String(localized: "这是 Preview 版。它的设置只属于自己，不会动到你正式装的那个 JoyHarness。"))
                        .font(.system(size: 12))
                        .foregroundStyle(JoyTheme.detail)
                        .padding(.horizontal, 4)
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return state.buildFlavor == "preview" ? String(localized: "版本 \(version) Preview") : String(localized: "版本 \(version)")
    }
}
