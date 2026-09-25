import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    // The practice field lives here rather than inside a step, so what the
    // user dictated in one step is still there to delete and send in the next.
    @State private var practiceText = ""
    @State private var sentMessages: [PracticeMessage] = []
    @FocusState private var practiceFocused: Bool
    @State private var pendingAdvance: Task<Void, Never>?
    /// Text changed after ZR was pressed: the user's voice tool is listening.
    @State private var voiceTextArrived = false

    private let hotspots = ControllerHotspotReader.load()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let check = state.currentOnboardingCheck {
                    HStack(spacing: 0) {
                        keyInstruction(check)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        practicePanel(check)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.025))
                    }
                } else {
                    HStack(spacing: 0) {
                        copy
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        visual
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.025))
                    }
                }
            }
            .id(state.onboardingStep)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(JoyMotion.stepTransition, value: state.onboardingStep)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("onboarding-root")
        .onChange(of: state.onboardingStep) { _ in prepareStep() }
        .onChange(of: state.onboardingWorkflowProgress) { _ in stepMaybeDone() }
        .onChange(of: practiceText) { _ in practiceTextChanged() }
        .onAppear { prepareStep() }
    }

    // MARK: - Frame

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
                ForEach(0..<state.onboardingStepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == state.onboardingStep ? JoyTheme.blue
                              : (index < state.onboardingStep ? JoyTheme.blue.opacity(0.35) : Color.primary.opacity(0.15)))
                        .frame(width: index == state.onboardingStep ? 18 : 7, height: 7)
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

    private var footer: some View {
        HStack {
            Button("上一步") {
                state.onboardingStep = max(0, state.onboardingStep - 1)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.onboardingStep == 0)
            Spacer()
            Button(isLastStep ? "开始用" : "继续") { advance() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canContinue)
                .accessibilityIdentifier("onboarding-next")
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
    }

    // MARK: - Setup steps

    private var copy: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(lead: setupTitle.lead, main: setupTitle.main)
            Text(setupBody)
                .font(.system(size: 15))
                .foregroundStyle(JoyTheme.detail)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if state.onboardingStep == AppState.onboardingConnectStep {
                pairingSteps
            }
            Spacer()
        }
        // Same edge and height as the key steps, so the title does not jump
        // about as the walkthrough moves from one kind of step to the other.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 48)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var visual: some View {
        switch state.onboardingStep {
        case 0: welcomeVisual
        case 1: permissionVisual
        default: connectionVisual
        }
    }

    /// Two weights in one title, after Typeless: the lead-in is quiet and the
    /// part that says what to do carries the weight, so the eye lands on it.
    private func stepTitle(lead: String, main: String) -> some View {
        (Text(lead).foregroundColor(.secondary) + Text(main))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var setupTitle: (lead: String, main: String) {
        switch state.onboardingStep {
        case 0: return ("把语音输入", "握在手里")
        case 1: return ("先让 JoyHarness ", "替你按键")
        default: return ("连上", "一只手柄")
        }
    }

    private var setupBody: String {
        switch state.onboardingStep {
        case 0: return "X 聚焦、ZR 说话、A 发送。一只手就够。"
        case 1: return "它不读你打的字，也不记录你按了什么。"
        default: return "左右手柄都行，连一只就能用。"
        }
    }

    private var welcomeVisual: some View {
        Group {
            if let image = state.imageResource(named: "JoyConPair") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 400, maxHeight: 330)
            }
        }
        .padding(34)
    }

    // MARK: Permission

    private var permissionVisual: some View {
        VStack(spacing: 22) {
            AccessibilityToggleMock(granted: state.accessibilityGranted, icon: state.appIcon)
                .frame(maxWidth: 360)
            if state.accessibilityGranted {
                StatusPill(text: "已授权", color: JoyTheme.green)
            } else {
                Button("前往授权", action: state.requestAccessibility)
                    .buttonStyle(PrimaryButtonStyle())
            }
            // No "check again" button: authorization is polled once a second,
            // so this turns green on its own the moment the grant lands. Asking
            // the user to come back and confirm their own action is a chore,
            // not a check.
        }
        .animation(JoyMotion.stateChange, value: state.accessibilityGranted)
        .padding(44)
    }

    // MARK: Connection

    /// How to put a Joy-Con into pairing mode. The original project's README
    /// had one line on this -- hold the small button on the rail -- and that
    /// line is exactly what a first-time owner does not know: the button is
    /// on the side that slides into the console, not on the face.
    private var pairingSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            pairingStep(1, "按住手柄侧面滑轨上的小圆钮，直到指示灯来回闪")
            pairingStep(2, "在蓝牙设置里点 Joy-Con 旁的「连接」")
            pairingStep(3, "连上时手柄会震一下")
            // The two ways "it won't connect" actually happens: a controller
            // that knows this Mac just needs waking; one that has since been
            // paired to a Switch has forgotten the Mac and must pair again.
            Text("连过这台 Mac 的手柄，按任意键就会自己连回来。点「连接」没反应，多半是它后来连过 Switch：在蓝牙列表里移除它，从第 1 步再来。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func pairingStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(JoyTheme.blue)
                .frame(width: 22, height: 22)
                .background(JoyTheme.blue.opacity(0.12))
                .clipShape(Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionVisual: some View {
        VStack(spacing: 22) {
            if let image = state.imageResource(named: "JoyConPair") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 290)
                    .overlay {
                        // The sync button sits mid-rail on each controller,
                        // beside the player lights. Pulsing until one connects.
                        if !hasOnboardingController {
                            GeometryReader { proxy in
                                ForEach(Self.pairRailPoints, id: \.x) { point in
                                    PulseRing(color: JoyTheme.blue, size: 22)
                                        .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                                }
                            }
                        }
                    }
            }
            // Either side can drive everything from here on, and both are
            // named when both are on -- saying "右 Joy-Con 已连接" while the
            // left one is also connected reads as though the left had failed.
            StatusPill(
                text: connectedControllerSummary,
                color: hasOnboardingController ? JoyTheme.green : JoyTheme.orange
            )
            .animation(JoyMotion.stateChange, value: connectedControllerSummary)

            // Hidden rather than removed once connected, so the picture
            // does not jump down the moment the controller arrives.
            Button("打开蓝牙设置") { state.openBluetoothSettings() }
                .buttonStyle(SecondaryButtonStyle())
                .opacity(hasOnboardingController ? 0 : 1)
                .disabled(hasOnboardingController)
        }
        .padding(38)
    }

    /// Mid-rail on each controller in joycon-pair.png, as fractions of the
    /// drawn image. The rails face each other and lean outward.
    private static let pairRailPoints: [CGPoint] = [
        CGPoint(x: 0.442, y: 0.49),
        CGPoint(x: 0.572, y: 0.49)
    ]

    private var connectedControllerSummary: String {
        switch (state.leftController.connected, state.rightController.connected) {
        case (true, true): return "左右 Joy-Con 已连接"
        case (true, false): return "左 Joy-Con 已连接"
        case (false, true): return "右 Joy-Con 已连接"
        case (false, false): return "等待 Joy-Con 连接"
        }
    }

    // MARK: - Key steps

    /// Left half of a key step: what to press, and where it is on the
    /// controller in hand -- the key pulses, and lights up while pressed.
    private func keyInstruction(_ check: OnboardingCheck) -> some View {
        let title = lessonTitle(check.lesson)
        return VStack(alignment: .leading, spacing: 16) {
            stepTitle(lead: title.lead, main: title.main)
            HStack(spacing: 8) {
                Text("按一下")
                KeyCapChip(text: check.key, prominent: true)
                Text("发出")
                KeyCapChip(text: check.shortcut, prominent: false)
            }
            .font(.system(size: 15))
            .foregroundStyle(JoyTheme.detail)

            if check.lesson == .voice {
                // Without this, a new user presses ZR, nothing visible
                // happens, and the product looks broken -- which is exactly
                // what it looks like when it is working correctly.
                Text("说的话怎么变成字，由你自己选的语音输入法完成：先在它里面把启动快捷键设成 fn。Typeless、豆包都行，换成别的也可以。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blocker = shortcutBlocker {
                Text(blocker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JoyTheme.orange)
            }

            Spacer(minLength: 8)
            HStack {
                Spacer()
                controllerFigure(for: check)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 40)
    }

    private func lessonTitle(_ lesson: OnboardingLesson) -> (lead: String, main: String) {
        switch lesson {
        case .focus: return ("先，", "把光标放进输入框")
        case .voice: return ("然后，", "说句话")
        case .delete: return ("说错了，", "删一个字")
        case .send: return ("最后，", "发出去")
        }
    }

    @ViewBuilder
    private func controllerFigure(for check: OnboardingCheck) -> some View {
        let side = state.onboardingSide
        let points = hotspots[side] ?? [:]
        let cards = state.mappingCards(for: side)
        let hotspotFor: (String) -> ControllerHotspot? = { button in
            cards.first(where: { $0.id == button }).flatMap { points[$0.hotspotKey] }
        }
        if let image = state.imageResource(named: side.imageName) {
            ControllerFigure(
                image: image,
                side: side,
                target: points[check.hotspotKey],
                targetLabel: check.key,
                targetDone: state.onboardingWorkflowHas(check.id),
                lit: state.onboardingPressedButtons.compactMap(hotspotFor),
                flash: state.onboardingPressFlash,
                flashPoint: hotspotFor(state.onboardingPressFlash.button),
                height: 300
            )
        }
    }

    /// Right half of a key step: a small composer where the key really does
    /// its job. Pressing X really moves the cursor here, ZR really wakes the
    /// user's voice tool, B really deletes and A really sends.
    private func practicePanel(_ check: OnboardingCheck) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.primary.opacity(0.14)).frame(width: 9, height: 9)
                }
                Spacer()
                // Pressing A here "sends" -- say plainly that it goes nowhere,
                // or a careful user will hesitate over the one key the step
                // is asking for.
                Text("练习用，不会发给任何人")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(sentMessages) { message in
                            Text(message.text)
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(JoyTheme.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .frame(maxWidth: 300, alignment: .trailing)
                                .id(message.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(16)
                }
                .onChange(of: sentMessages.count) { _ in
                    if let last = sentMessages.last {
                        withAnimation(JoyMotion.stateChange) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            practiceStatus(check)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            TextField("", text: $practiceText, prompt: Text(practicePlaceholder(check)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(3...6)
                .focused($practiceFocused)
                .onSubmit(sendPractice)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(practiceFocused ? JoyTheme.blue : JoyTheme.cardBorder,
                                lineWidth: practiceFocused ? 2 : 1)
                }
                .animation(JoyMotion.hover, value: practiceFocused)
                .accessibilityIdentifier("onboarding-practice-field")
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(JoyTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(JoyTheme.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .padding(.horizontal, 36)
        .padding(.vertical, 40)
    }

    /// The placeholder names the key, the way Typeless's playground says
    /// "press fn once to start speaking" -- the field itself is the prompt.
    private func practicePlaceholder(_ check: OnboardingCheck) -> String {
        switch check.lesson {
        case .focus: return "按一下 \(check.key)，光标就会来这里"
        case .voice: return "按一下 \(check.key)，开始说话…"
        case .delete, .send: return ""
        }
    }

    @ViewBuilder
    private func practiceStatus(_ check: OnboardingCheck) -> some View {
        let done = state.onboardingWorkflowHas(check.id)
        HStack(spacing: 6) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(JoyTheme.green)
                Text(doneText(check))
            } else {
                Text(waitingText(check))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12, weight: .semibold))
        .animation(JoyMotion.stateChange, value: done)
    }

    private func doneText(_ check: OnboardingCheck) -> String {
        switch check.lesson {
        case .focus: return "光标到位"
        case .voice: return voiceTextArrived ? "收到了" : "\(check.shortcut) 已发出。说完了点继续"
        case .delete: return "删掉了"
        case .send: return "发出去了"
        }
    }

    private func waitingText(_ check: OnboardingCheck) -> String {
        switch check.lesson {
        case .focus: return "等你按 \(check.key)"
        case .voice: return "等你按 \(check.key)"
        case .delete: return "按一下 \(check.key)，删掉最后一个字"
        case .send: return "按一下 \(check.key)，把它发出去"
        }
    }

    // MARK: - Flow

    /// Each key step starts from a state where its key visibly does
    /// something: the cursor away from the field for X, in it for the rest,
    /// and something in the field to delete and to send.
    private func prepareStep() {
        pendingAdvance?.cancel()
        pendingAdvance = nil
        guard let check = state.currentOnboardingCheck else { return }
        if check.lesson == .voice { voiceTextArrived = false }
        if check.lesson == .delete || check.lesson == .send,
           practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            practiceText = String(localized: "明天下午三点开会")
        }
        // The step's views are rebuilt on every step change, so focus set
        // now would land on the field that is about to go away. Once the
        // new one is in place:
        let step = state.onboardingStep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard state.onboardingStep == step else { return }
            if check.lesson == .focus {
                // Nothing else in the window takes the cursor, so the field
                // is plainly empty-handed until X puts it there.
                practiceFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            } else {
                practiceFocused = true
                // A text field that takes focus selects everything in it, and
                // one press of ⌫ then clears the whole sentence -- the step
                // says "delete one character". Put the cursor at the end.
                DispatchQueue.main.async {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
            }
        }
    }

    private func stepMaybeDone() {
        guard let check = state.currentOnboardingCheck,
              state.onboardingWorkflowHas(check.id),
              pendingAdvance == nil,
              !isLastStep else { return }
        // Voice waits for the user: they are mid-sentence when the press
        // registers. It moves on once their words have landed, below.
        guard check.lesson != .voice else { return }
        scheduleAdvance(after: 0.9)
    }

    private func practiceTextChanged() {
        guard let check = state.currentOnboardingCheck, check.lesson == .voice,
              state.onboardingWorkflowHas(check.id),
              !practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        voiceTextArrived = true
        // Dictation tools stream text in; wait for it to settle.
        pendingAdvance?.cancel()
        pendingAdvance = nil
        scheduleAdvance(after: 1.8)
    }

    private func scheduleAdvance(after seconds: Double) {
        let step = state.onboardingStep
        pendingAdvance = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, state.onboardingStep == step else { return }
            pendingAdvance = nil
            advance()
        }
    }

    private func sendPractice() {
        let text = practiceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            sentMessages.append(PracticeMessage(text: text))
        }
        practiceText = ""
    }

    private func advance() {
        if isLastStep {
            state.dismissOnboarding(markCompleted: true)
        } else {
            if state.onboardingStep == AppState.onboardingConnectStep {
                state.beginOnboardingWorkflowMonitoring()
            }
            state.onboardingStep += 1
        }
    }

    private var isLastStep: Bool { state.onboardingStep >= state.onboardingStepCount - 1 }

    private var canContinue: Bool {
        if let check = state.currentOnboardingCheck {
            return state.onboardingWorkflowHas(check.id)
        }
        switch state.onboardingStep {
        case 1: return state.permissionsSatisfied
        case AppState.onboardingConnectStep: return hasOnboardingController
        default: return true
        }
    }

    private var shortcutBlocker: String? {
        if !state.serviceRunning { return "JoyHarness 现在没在运行。" }
        if !state.permissionsSatisfied { return "要先授权。" }
        if !hasOnboardingController { return "要先连上一只手柄。" }
        return nil
    }

    private var hasOnboardingController: Bool {
        state.leftController.connected || state.rightController.connected
    }
}

private struct PracticeMessage: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Pieces

/// A keycap in running text: the controller key in blue, the shortcut it
/// sends in the neutral key style.
private struct KeyCapChip: View {
    let text: String
    let prominent: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(prominent ? .white : .primary)
            .padding(.horizontal, 9)
            .frame(minWidth: 30, minHeight: 26)
            .background(prominent ? JoyTheme.blue : Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottom) {
                // A thin lower lip, so it reads as a key and not a tag.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.black.opacity(prominent ? 0.18 : 0.08), lineWidth: 1)
            }
    }
}

/// A ring that grows and fades, over and over: "here".
private struct PulseRing: View {
    let color: Color
    let size: CGFloat
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 2.5)
                .frame(width: size, height: size)
            Circle()
                .stroke(color.opacity(expanded ? 0 : 0.7), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(expanded ? 1.9 : 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
    }
}

/// The controller in hand with the key to press marked on it.
///
/// Hotspots are fractions of the 310×410 box the 按键 page draws the image
/// into (scaled to fit), with the same right-side optical correction -- so
/// one calibration serves both pages.
private struct ControllerFigure: View {
    let image: NSImage
    let side: ControllerSide
    let target: ControllerHotspot?
    let targetLabel: String
    let targetDone: Bool
    let lit: [ControllerHotspot]
    let flash: OnboardingPressFlash
    let flashPoint: ControllerHotspot?
    let height: CGFloat

    @State private var flashing = false

    private var scale: CGFloat { height / 410 }
    private var width: CGFloat { 310 * scale }

    private func point(_ hotspot: ControllerHotspot) -> CGPoint {
        CGPoint(
            x: hotspot.x * width,
            y: hotspot.y * height + (side == .right ? 8 * scale : 0)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 7)

            // Lit while held, after Typeless's key that turns blue under your
            // finger: proof the press arrived, before anything else happens.
            ForEach(Array(lit.enumerated()), id: \.offset) { _, hotspot in
                Circle()
                    .fill(JoyTheme.blue.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .position(point(hotspot))
            }
            if flashing, let flashPoint {
                Circle()
                    .fill(JoyTheme.blue.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .position(point(flashPoint))
                    .transition(.opacity)
            }

            if let target {
                let at = point(target)
                Group {
                    if targetDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, JoyTheme.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        PulseRing(color: JoyTheme.blue, size: 30)
                    }
                }
                .position(at)

                // The callout sits on the open side of the key, so it never
                // covers the controller's own face.
                let onRight = target.x < 0.5
                Text(targetLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(JoyTheme.blue)
                    .clipShape(Capsule())
                    .fixedSize()
                    .position(x: onRight ? width + 26 : -26, y: at.y)
                Path { path in
                    path.move(to: CGPoint(x: at.x + (onRight ? 17 : -17), y: at.y))
                    path.addLine(to: CGPoint(x: onRight ? width + 8 : -8, y: at.y))
                }
                .stroke(JoyTheme.blue.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .frame(width: width, height: height)
        .animation(JoyMotion.press, value: lit.count)
        .animation(JoyMotion.stateChange, value: targetDone)
        .onChange(of: flash) { _ in
            flashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.2)) { flashing = false }
            }
        }
    }
}

/// A drawing of the row the user is looking for in System Settings, after
/// Typeless's mock of the permission dialog: people find a switch faster
/// when they have already seen what it looks like.
private struct AccessibilityToggleMock: View {
    let granted: Bool
    let icon: NSImage?
    @State private var demoOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("系统设置 › 隐私与安全性 › 辅助功能")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 11) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                }
                Text("JoyHarness")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Capsule()
                    .fill(isOn ? JoyTheme.blue : Color.primary.opacity(0.18))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            .padding(2)
                    }
            }
            .padding(14)
            .background(JoyTheme.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(JoyTheme.cardBorder, lineWidth: 1)
            }
        }
        .task(id: granted) {
            // Until the grant lands, the switch shows how it is done: off,
            // then on, then again. Once granted it simply stays on.
            guard !granted else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.3)) { demoOn = false }
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                withAnimation(.easeInOut(duration: 0.3)) { demoOn = true }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
            }
        }
    }

    private var isOn: Bool { granted || demoOn }
}
