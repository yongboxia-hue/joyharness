import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                copy
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                visual
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.025))
            }
            .id(state.onboardingStep)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(JoyMotion.stepTransition, value: state.onboardingStep)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("onboarding-root")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = state.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
            }
            Text("JoyHarness")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == state.onboardingStep ? JoyTheme.blue : Color.primary.opacity(0.15))
                        .frame(width: index == state.onboardingStep ? 8 : 7, height: index == state.onboardingStep ? 8 : 7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.onboardingStep)
            Spacer()
            Button("稍后设置") { state.dismissOnboarding() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .accessibilityIdentifier("onboarding-skip")
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("第 \(state.onboardingStep + 1) 步，共 \(stepCount) 步")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(JoyTheme.blue)
            Text(stepTitle)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(stepBody)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if state.onboardingStep == 0 {
                Text("语音识别由你自己选的输入法完成，JoyHarness 不含这一段。我们自己用 Typeless 和豆包，换成别的也可以。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.onboardingStep == AppState.onboardingButtonTestStep {
                VStack(alignment: .leading, spacing: 8) {
                    Text("左、右 Joy-Con 都可以独立配置；下面按的是当前连着的那只。")
                    // 没有这句，新用户按下 fn 什么也不会发生，然后判定产品坏了 ——
                    // 而这恰恰是它在正常工作：JoyHarness 的责任到"发出快捷键"为止。
                    Text("其中 fn 是语音输入的启动键。JoyHarness 只负责把它发出去，"
                         + "要让它有反应，得先在你的语音输入法里把启动快捷键设成 fn。")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(48)
    }

    @ViewBuilder
    private var visual: some View {
        switch state.onboardingStep {
        case 0: controllerVisual
        case 1: permissionVisual
        case 2: connectionVisual
        default: shortcutVisual
        }
    }

    private var controllerVisual: some View {
        VStack(spacing: 24) {
            if let image = state.imageResource(named: "JoyConPair") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 390, maxHeight: 320)
            }
            Text("按自己的习惯配置每个按键")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(34)
    }

    private var permissionVisual: some View {
        VStack(spacing: 16) {
            onboardingRow(
                symbol: "keyboard.badge.ellipsis",
                title: "辅助功能",
                detail: "用于发送你配置的快捷键",
                complete: state.accessibilityGranted,
                action: state.requestAccessibility
            )
            // No "check again" button: authorization is polled once a second,
            // so this turns green on its own the moment the grant lands. Asking
            // the user to come back and confirm their own action is a chore,
            // not a check.
        }
        .padding(52)
    }

    private var connectionVisual: some View {
        VStack(spacing: 22) {
            if let image = state.imageResource(named: "JoyConPair") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 350, maxHeight: 280)
            }
            // Either side can drive everything from here on, and both are
            // named when both are on -- saying "右 Joy-Con 已连接" while the
            // left one is also connected reads as though the left had failed.
            StatusPill(
                text: connectedControllerSummary,
                color: hasOnboardingController ? JoyTheme.green : JoyTheme.orange
            )
            .animation(JoyMotion.stateChange, value: connectedControllerSummary)

            if !hasOnboardingController {
                Button("打开蓝牙设置") { state.openBluetoothSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(38)
    }

    private var connectedControllerSummary: String {
        switch (state.leftController.connected, state.rightController.connected) {
        case (true, true): return "左右 Joy-Con 已连接"
        case (true, false): return "左 Joy-Con 已连接"
        case (false, true): return "右 Joy-Con 已连接"
        case (false, false): return "等待 Joy-Con 连接"
        }
    }

    /// The checks come from AppState, which reads them off the mappings that
    /// are actually installed -- this view used to keep its own table of
    /// "ZR is fn, + is ⌘V" and would go on teaching it after a remap.
    private var workflowChecks: [OnboardingCheck] { state.onboardingChecks }

    /// The first check that has not happened yet -- the only one shown.
    private var pendingCheck: (offset: Int, element: OnboardingCheck)? {
        workflowChecks.enumerated().first { !state.onboardingWorkflowHas($0.element.id) }
    }

    private var shortcutVisual: some View {
        VStack(spacing: 18) {
            // One key at a time. Showing all four at once turned the step into
            // a checklist to decipher; the user only ever needs to know what
            // to press right now.
            if let pending = pendingCheck {
                Text("第 \(pending.offset + 1) 步，共 \(workflowChecks.count) 步")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                shortcutKey(
                    pending.element.key,
                    pending.element.shortcut,
                    pending.element.gesture,
                    progress: pending.element.id
                )
                .id(pending.element.id)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))

                Text("\(pending.element.gesture) \(pending.element.key)　·　对应 \(pending.element.shortcut)")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 6) {
                    ForEach(Array(workflowChecks.enumerated()), id: \.offset) { index, check in
                        Circle()
                            .fill(state.onboardingWorkflowHas(check.id)
                                  ? JoyTheme.green
                                  : (index == pending.offset ? JoyTheme.blue : Color.primary.opacity(0.16)))
                            .frame(width: 7, height: 7)
                    }
                }
            } else {
                Label("\(workflowChecks.count) 项按键都检测到了", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JoyTheme.green)
            }

            if !state.serviceRunning || !state.permissionsSatisfied || !hasOnboardingController {
                Text(shortcutBlocker)
                    .font(.system(size: 11))
                    .foregroundStyle(JoyTheme.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(JoyMotion.stateChange, value: state.onboardingWorkflowProgress)
        .padding(42)
    }

    private func onboardingRow(
        symbol: String,
        title: String,
        detail: String,
        complete: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(complete ? JoyTheme.green : JoyTheme.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if complete {
                StatusPill(text: "已授权", color: JoyTheme.green)
            } else {
                Button("前往授权", action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func shortcutKey(_ key: String, _ shortcut: String, _ gesture: String, progress: String) -> some View {
        let done = state.onboardingWorkflowHas(progress)
        return VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Text(key)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .frame(width: 52, height: 52)
                    .background(done ? JoyTheme.green.opacity(0.16) : Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if done {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(JoyTheme.green.opacity(0.55), lineWidth: 1)
                        }
                    }
                // Two different physical keys ("+") appear back to back for a
                // short tap vs. a long press. Without this badge they read as
                // duplicates at a glance — the badge makes the long-press one
                // visually distinct, not just via the caption text below.
                if gesture == "按住不放" {
                    Image(systemName: "timer")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(JoyTheme.orange)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .scaleEffect(done ? 1.04 : 1)
            .animation(.easeOut(duration: 0.18), value: done)
            Text(shortcut)
                .font(.system(size: 12, weight: .semibold))
            Text(gesture)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: 68)
    }

    private var footer: some View {
        HStack {
            Button("上一步") {
                state.onboardingStep = max(0, state.onboardingStep - 1)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.onboardingStep == 0)
            Spacer()
            Button(nextTitle) {
                if state.onboardingStep < stepCount - 1 {
                    if state.onboardingStep == 2 {
                        state.beginOnboardingWorkflowMonitoring()
                    }
                    state.onboardingStep += 1
                } else {
                    state.dismissOnboarding(markCompleted: true)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canContinue)
            .accessibilityIdentifier("onboarding-next")
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
    }

    private var stepTitle: String {
        ["把语音工作流握在手里", "允许必要权限", "连接任意一只 Joy-Con", "完成第一次按键测试"][state.onboardingStep]
    }

    private var stepBody: String {
        [
            "用任意一只 Joy-Con 启动语音输入、连续听写和确认发送，减少双手在键盘和鼠标之间来回切换。每个按键发什么快捷键，都由你自己配置。",
            "辅助功能权限让 JoyHarness 能够发送快捷键。JoyHarness 不监听你的键盘输入，也不读取输入内容。",
            "在系统蓝牙设置中连接任意一只 Joy-Con，连上就会自动继续。",
            "按提示逐个试一下。这一步只是确认手柄有反应，按键不会真的发出快捷键。检测到了会自动跳到下一步。"
        ][state.onboardingStep]
    }

    private var canContinue: Bool {
        switch state.onboardingStep {
        case 1: return state.permissionsSatisfied
        case 2: return hasOnboardingController
        case AppState.onboardingButtonTestStep: return state.onboardingWorkflowConfirmed
        default: return true
        }
    }

    private var nextTitle: String {
        state.onboardingStep == stepCount - 1 ? "进入 JoyHarness" : "继续"
    }

    private var shortcutBlocker: String {
        if !state.serviceRunning { return "JoyHarness 暂时没有在运行。" }
        if !state.permissionsSatisfied { return "需要先完成辅助功能授权。" }
        return "需要先连接任意一只 Joy-Con。"
    }

    private var hasOnboardingController: Bool {
        state.leftController.connected || state.rightController.connected
    }
}
