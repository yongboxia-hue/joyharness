import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    // The practice lives here rather than inside a step, so what the user
    // dictated in one step is still there to delete and send in the next.
    @State private var practiceText = ""
    @State private var messages: [PracticeMessage] = [
        PracticeMessage(text: String(localized: "明天几点开会？"), mine: false)
    ]
    @FocusState private var practiceFocused: Bool
    @State private var pendingAdvance: Task<Void, Never>?
    /// Text changed after ZR was pressed: the user's voice tool is listening.
    @State private var voiceTextArrived = false
    /// ZR presses in the current voice step. Most voice tools start on one
    /// tap and stop on the next, and a first-time user does not know there
    /// is a second -- so the step says so between the two.
    @State private var voicePresses = 0
    /// The last ZR press was a hold: a hold-to-talk tool, no second press.
    @State private var voiceHeld = false
    /// Stopped talking a while ago and still nothing in the field.
    @State private var voiceNoText = false
    /// The practice window is on screen. Steps inside the practice do not
    /// rebuild it; only arriving from another page does.
    @State private var practiceMounted = false
    /// What was on the clipboard before the paste step put its sentence
    /// there, and the change count right after it did -- restored only if
    /// nothing else has been copied since.
    @State private var savedClipboard: SavedClipboard?

    private let hotspots = ControllerHotspotReader.load()

    // The script. The first exchange answers "when"; the reply asks "where",
    // and the second answers that with everything done to a message before
    // it goes. Each line doubles as the fallback when a step is skipped.
    private var firstLine: String { String(localized: "明天下午三点，在三楼会议室。") }
    /// Pasted with a tail to cut off, because that is what copied text is
    /// usually like -- and it gives the held ⌫ something real to do.
    private var pastedAddress: String { String(localized: "三楼 305，出电梯右手边。（摘自行政通知）") }
    private var trimmedAddress: String { String(localized: "三楼 305，出电梯右手边。") }
    private var secondLine: String { String(localized: "我先过去等你。") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let check = state.currentOnboardingCheck {
                    practiceStage(check)
                } else if isFinishStep {
                    finishPage
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
            // The four keys are one page. Rebuilding it on every key made the
            // screen blink after each press, which reads as the input being
            // interrupted -- and it threw away the field's focus each time.
            .id(pageID)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(JoyMotion.stepTransition, value: pageID)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("onboarding-root")
        .onChange(of: state.onboardingStep) { _ in prepareStep() }
        .onChange(of: state.onboardingWorkflowProgress) { _ in stepMaybeDone() }
        .onChange(of: practiceText) { _ in practiceTextChanged() }
        .onChange(of: state.onboardingPressFlash) { flash in voicePressed(flash) }
        .onAppear { prepareStep() }
        .onDisappear { restoreClipboard() }
    }

    private var isPracticeStep: Bool { state.currentOnboardingCheck != nil }
    private var isFinishStep: Bool { state.onboardingStep >= state.onboardingFinishStep }
    private var pageID: String { isPracticeStep ? "practice" : "step-\(state.onboardingStep)" }

    /// Welcome, permission, connect, practice, done: the dots count pages,
    /// not keys -- the keys have their own dots on the practice page.
    private var stageIndex: Int {
        if isFinishStep { return 4 }
        if isPracticeStep { return 3 }
        return min(state.onboardingStep, 2)
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
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(index == stageIndex ? JoyTheme.blue
                              : (index < stageIndex ? JoyTheme.blue.opacity(0.35) : Color.primary.opacity(0.15)))
                        .frame(width: index == stageIndex ? 18 : 7, height: 7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: stageIndex)
            Spacer()
            Button(String(localized: "稍后设置")) { state.dismissOnboarding() }
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
            Button(String(localized: "上一步")) {
                state.onboardingStep = max(0, state.onboardingStep - 1)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.onboardingStep == 0)
            Spacer()
            if isPracticeStep {
                // No blue button while practising: the practice's own goal is
                // "send", and a primary button in the corner reads as the
                // send button. Each key moves on by itself once it works;
                // this is for a step that cannot, like voice with no tool set up.
                Button(String(localized: "跳过这一步")) { advance() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("onboarding-skip-step")
            } else {
                Button(isFinishStep ? String(localized: "开始使用") : String(localized: "继续")) { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canContinue)
                    .accessibilityIdentifier("onboarding-next")
            }
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
        case 0: return (String(localized: "把语音输入"), String(localized: "握在手里"))
        case 1: return (String(localized: "先让 JoyHarness "), String(localized: "替你按键"))
        default: return (String(localized: "连上"), String(localized: "一只手柄"))
        }
    }

    private var setupBody: String {
        switch state.onboardingStep {
        case 0: return String(localized: "X 聚焦、ZR 说话、A 发送。一只手就够。")
        case 1: return String(localized: "它不读你打的字，也不记录你按了什么。")
        default: return String(localized: "左右手柄都行，连一只就能用。")
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
                StatusPill(text: String(localized: "已授权"), color: JoyTheme.green)
            } else {
                Button(String(localized: "前往授权"), action: state.requestAccessibility)
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
            pairingStep(1, String(localized: "按住手柄侧面滑轨上的小圆钮，直到指示灯来回闪"))
            pairingStep(2, String(localized: "在蓝牙设置里点 Joy-Con 旁的「连接」"))
            pairingStep(3, String(localized: "连上时手柄会震一下"))
            // The two ways "it won't connect" actually happens: a controller
            // that knows this Mac just needs waking; one that has since been
            // paired to a Switch has forgotten the Mac and must pair again.
            Text(String(localized: "连过这台 Mac 的手柄，按任意键就会自己连回来。点「连接」没反应，多半是它后来连过 Switch：在蓝牙列表里移除它，从第 1 步再来。"))
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
            Button(String(localized: "打开蓝牙设置")) { state.openBluetoothSettings() }
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
        case (true, true): return String(localized: "左右 Joy-Con 已连接")
        case (true, false): return String(localized: "左 Joy-Con 已连接")
        case (false, true): return String(localized: "右 Joy-Con 已连接")
        case (false, false): return String(localized: "等待 Joy-Con 连接")
        }
    }

    // MARK: - Practice

    /// All the keys on one page. The words sit on the right, directly above
    /// the field, because that is where the eyes are while talking and
    /// typing: with them on the left, reading one side meant missing what
    /// happened on the other. The left keeps only the controller, to be
    /// found with a glance rather than read.
    private func practiceStage(_ check: OnboardingCheck) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                controllerSide(check)
                    .frame(width: proxy.size.width * 0.32)
                    .frame(maxHeight: .infinity)
                practicePanel(check)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.025))
            }
        }
        .onAppear { practiceMounted = true }
        .onDisappear { practiceMounted = false }
    }

    private func controllerSide(_ check: OnboardingCheck) -> some View {
        let roundChecks = state.onboardingChecks.filter { $0.round == check.round }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(check.round == 1 ? String(localized: "第一轮") : String(localized: "第二轮"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    ForEach(roundChecks) { item in
                        Circle()
                            .fill(stepDone(item) ? JoyTheme.green
                                  : (item.id == check.id ? JoyTheme.blue : Color.primary.opacity(0.16)))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            Spacer(minLength: 12)
            HStack {
                Spacer()
                controllerFigure(for: check)
                Spacer()
            }
            Spacer(minLength: 12)
        }
        .animation(JoyMotion.stateChange, value: check.id)
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
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
                targetDone: stepDone(check),
                lit: state.onboardingPressedButtons.compactMap(hotspotFor),
                flash: state.onboardingPressFlash,
                flashPoint: hotspotFor(state.onboardingPressFlash.button),
                height: 320
            )
        }
    }

    /// Right side: a conversation where the keys really do their job, with
    /// the instruction for the current key pinned just above the field.
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
                Text(String(localized: "练习用，不会发给任何人"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(messages) { message in
                            HStack {
                                if message.mine { Spacer(minLength: 60) }
                                Text(message.text)
                                    .font(.system(size: 15))
                                    .foregroundStyle(message.mine ? Color.white : Color.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(message.mine ? JoyTheme.blue : Color.primary.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                if !message.mine { Spacer(minLength: 60) }
                            }
                            .id(message.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(18)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation(JoyMotion.stateChange) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            coachBar(check)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            TextField("", text: $practiceText, prompt: Text(practicePlaceholder(check)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(3...8)
                .focused($practiceFocused)
                .onSubmit(submitPractice)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(practiceFocused ? JoyTheme.blue : JoyTheme.cardBorder,
                                lineWidth: practiceFocused ? 2 : 1)
                }
                .animation(JoyMotion.hover, value: practiceFocused)
                .accessibilityIdentifier("onboarding-practice-field")
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .background(JoyTheme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(JoyTheme.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.07), radius: 16, y: 6)
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
    }

    /// The instruction, where the eyes already are. It changes in place from
    /// key to key, sliding up the way Typeless moves its instructions.
    private func coachBar(_ check: OnboardingCheck) -> some View {
        let done = stepDone(check)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                KeyCapChip(text: check.key, prominent: true)
                if voiceListening(check) {
                    PulseDot(color: JoyTheme.red)
                }
                Text(instruction(check))
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if done {
                    Label(doneText(check), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JoyTheme.green)
                        .transition(.opacity)
                }
            }
            if let line = readAloud(check) {
                Text(line)
                    .font(.system(size: 17, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if check.lesson == .voice, check.round == 1, voicePresses == 0, !voiceNoText {
                // The one thing that has to be true before ZR does anything
                // visible -- and without it a new user presses, sees nothing,
                // and decides the product is broken. Just this, at weight;
                // how dictation works and which tool to use are not the
                // user's problem until something goes wrong.
                HStack(spacing: 6) {
                    Text(String(localized: "先在你的语音输入法里，把启动快捷键设成"))
                    KeyCapChip(text: "fn", prominent: false)
                }
                .font(.system(size: 13, weight: .medium))
            }
            if let note = note(check, done: done) {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blocker = shortcutBlocker {
                Text(blocker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JoyTheme.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JoyTheme.blue.opacity(done ? 0.03 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((done ? JoyTheme.green : JoyTheme.blue).opacity(0.3), lineWidth: 1)
        }
        .id(check.id)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        ))
        .animation(JoyMotion.stateChange, value: done)
        .animation(.easeInOut(duration: 0.3), value: check.id)
    }

    /// A voice step counts once the words are in the field; the press alone
    /// only started the listening. Every other step counts on the press.
    private func stepDone(_ check: OnboardingCheck) -> Bool {
        guard state.onboardingWorkflowHas(check.id) else { return false }
        if check.lesson == .voice, check.id == state.currentOnboardingCheck?.id {
            return voiceTextArrived
        }
        return true
    }

    private func voiceListening(_ check: OnboardingCheck) -> Bool {
        check.lesson == .voice && voicePresses % 2 == 1 && !voiceHeld && !voiceTextArrived
    }

    private func instruction(_ check: OnboardingCheck) -> String {
        switch check.lesson {
        case .focus: return String(localized: "按一下，把光标放进来")
        case .voice where voiceListening(check):
            return String(localized: "在听了。念完再按一下，结束说话")
        case .voice where voicePresses > 0 && !voiceTextArrived && !voiceNoText:
            return String(localized: "正在转成文字…")
        case .voice: return String(localized: "按一下开始说，照着念：")
        case .send: return String(localized: "按一下，发出去")
        case .paste: return String(localized: "按一下，把剪贴板里的地址贴进来")
        case .trim: return String(localized: "按住连着删，删掉括号那一截")
        case .newline: return String(localized: "按住换行，手柄震一下就松手")
        }
    }

    /// What to say, for the two voice steps. A new user facing a live
    /// microphone does not know what to say.
    private func readAloud(_ check: OnboardingCheck) -> String? {
        guard check.lesson == .voice else { return nil }
        return check.round == 1 ? firstLine : secondLine
    }

    private func note(_ check: OnboardingCheck, done: Bool) -> String? {
        switch check.lesson {
        case .voice where voiceNoText:
            // Only once something has gone wrong: the two reasons it does.
            return String(localized: "没出字？看看启动快捷键是不是 \(check.shortcut)；有的输入法要按住 \(check.key) 说话。")
        case .paste:
            return String(localized: "剪贴板里已经放好了这段地址。你原来复制的内容，这一步结束后会放回去。")
        case .trim:
            return String(localized: "删到句号就松手。")
        default:
            return nil
        }
    }

    /// The placeholder names the key, the way Typeless's playground says
    /// "press fn once to start speaking" -- the field itself is the prompt.
    private func practicePlaceholder(_ check: OnboardingCheck) -> String {
        switch check.lesson {
        case .focus: return String(localized: "按一下 \(check.key)，光标就会来这里")
        case .voice: return String(localized: "说的话会出现在这里")
        default: return ""
        }
    }

    private func doneText(_ check: OnboardingCheck) -> String {
        switch check.lesson {
        case .focus: return String(localized: "光标到位")
        case .voice: return String(localized: "收到了")
        case .send: return String(localized: "发出去了")
        case .paste: return String(localized: "贴上了")
        case .trim: return String(localized: "删掉了")
        case .newline: return String(localized: "换好行了")
        }
    }

    // MARK: - Done

    /// Its own page, after Typeless's "Speak, don't type": the practice
    /// ends on the message going out, and 开始使用 lives here alone rather
    /// than in the corner where the practice's own send button seemed to be.
    private var finishPage: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                stepTitle(lead: String(localized: "说话，"), main: String(localized: "不用打字"))
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(finishRows, id: \.key) { row in
                        HStack(spacing: 12) {
                            KeyCapChip(text: row.key, prominent: true)
                                .frame(width: 44, alignment: .leading)
                            Text(row.text)
                                .font(.system(size: 15))
                        }
                    }
                }
                .padding(18)
                .background(JoyTheme.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(JoyTheme.cardBorder, lineWidth: 1)
                }
                Text(String(localized: "每个键都能在「按键」页改。"))
                    .font(.system(size: 13))
                    .foregroundStyle(JoyTheme.detail)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            welcomeVisual
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025))
        }
    }

    /// One line per key, in the order they were taught. A key taught twice
    /// -- A sends, and holds for a new line -- says both on its one line.
    private var finishRows: [(key: String, text: String)] {
        let checks = state.onboardingChecks
        func key(_ lesson: OnboardingLesson) -> String? { checks.first { $0.lesson == lesson }?.key }
        let rows: [(String?, String)] = [
            (key(.focus), String(localized: "聚焦输入框")),
            (key(.voice), String(localized: "说话：按一下开始，再按一下结束")),
            (key(.paste), String(localized: "粘贴")),
            (key(.trim), String(localized: "删除，按住连着删")),
            (key(.send), key(.newline) != nil ? String(localized: "发送，按住换行") : String(localized: "发送"))
        ]
        return rows.compactMap { key, text in key.map { ($0, text) } }
    }

    // MARK: - Flow

    /// Each key starts from a state where it visibly does something: the
    /// cursor away from the field for X, in it for the rest, and something
    /// in the field for the keys that edit or send.
    private func prepareStep() {
        pendingAdvance?.cancel()
        pendingAdvance = nil
        let check = state.currentOnboardingCheck
        if check?.lesson != .paste { restoreClipboard() }
        guard let check else { return }
        if check.lesson == .voice {
            voiceTextArrived = false
            voicePresses = 0
            voiceHeld = false
            voiceNoText = false
        }

        // Fallbacks for a skipped step, so the next one has something to act
        // on. The paste step wants the field empty: it answers a new question.
        let empty = practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch check.lesson {
        case .send where empty: practiceText = check.round == 1 ? firstLine : trimmedAddress
        case .trim where empty: practiceText = pastedAddress
        case .newline where empty: practiceText = trimmedAddress
        case .paste: stageClipboard()
        default: break
        }

        // Arriving from another page builds the practice window, and focus
        // set before it exists goes nowhere. Moving between keys it is
        // already there.
        let step = state.onboardingStep
        let delay = practiceMounted ? 0.0 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard state.onboardingStep == step else { return }
            if check.lesson == .focus {
                // Nothing else in the window takes the cursor, so the field
                // is plainly empty-handed until X puts it there.
                practiceFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            } else {
                if !practiceFocused { practiceFocused = true }
                // A text field that takes focus selects everything in it, and
                // one press of ⌫ then clears the whole sentence. Put the
                // cursor at the end.
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
              pendingAdvance == nil else { return }
        switch check.lesson {
        // Voice waits for the user: they are mid-sentence when the press
        // registers. It moves on once their words have landed, below.
        case .voice: return
        // Long enough to see the message go and the answer come back.
        case .send: scheduleAdvance(after: 2.2)
        default: scheduleAdvance(after: 0.9)
        }
    }

    private func voicePressed(_ flash: OnboardingPressFlash) {
        guard let check = state.currentOnboardingCheck, check.lesson == .voice,
              flash.button == check.button, !voiceTextArrived else { return }
        voicePresses += 1
        voiceHeld = flash.held
        // Talking has ended -- a second tap, or letting go of a hold. The
        // words usually follow within a second; only if they do not is it
        // worth saying why they might not have.
        guard flash.held || voicePresses % 2 == 0 else { return }
        let step = state.onboardingStep
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard state.onboardingStep == step, !voiceTextArrived else { return }
            voiceNoText = true
        }
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

    private func stageClipboard() {
        guard savedClipboard == nil else { return }
        let board = NSPasteboard.general
        let items = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        board.clearContents()
        board.setString(pastedAddress, forType: .string)
        savedClipboard = SavedClipboard(items: items, changeCount: board.changeCount)
    }

    private func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let board = NSPasteboard.general
        // Something new was copied since: that is the user's now, keep it.
        guard board.changeCount == saved.changeCount else { return }
        board.clearContents()
        let items = saved.items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    /// Return sends; shift-return is A held, a new line. The field reports
    /// both as a submit, so the modifier on the event decides.
    private func submitPractice() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            practiceText += "\n"
            return
        }
        let text = practiceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            messages.append(PracticeMessage(text: text, mine: true))
        }
        practiceText = ""
        let reply = messages.filter(\.mine).count == 1
            ? String(localized: "好。会议室在哪？地址发我一下。")
            : String(localized: "好，一会儿见。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeInOut(duration: 0.3)) {
                messages.append(PracticeMessage(text: reply, mine: false))
            }
        }
    }

    private func advance() {
        if isFinishStep {
            state.dismissOnboarding(markCompleted: true)
        } else {
            if state.onboardingStep == AppState.onboardingConnectStep {
                state.beginOnboardingWorkflowMonitoring()
            }
            state.onboardingStep += 1
        }
    }

    private var canContinue: Bool {
        switch state.onboardingStep {
        case 1: return state.permissionsSatisfied
        case AppState.onboardingConnectStep: return hasOnboardingController
        default: return true
        }
    }

    private var shortcutBlocker: String? {
        if !state.serviceRunning { return String(localized: "JoyHarness 现在没在运行。") }
        if !state.permissionsSatisfied { return String(localized: "要先授权。") }
        if !hasOnboardingController { return String(localized: "要先连上一只手柄。") }
        return nil
    }

    private var hasOnboardingController: Bool {
        state.leftController.connected || state.rightController.connected
    }
}

private struct SavedClipboard {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int
}

private struct PracticeMessage: Identifiable {
    let id = UUID()
    let text: String
    let mine: Bool
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

/// A dot that breathes while the microphone is on.
private struct PulseDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
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
            Text(String(localized: "系统设置 › 隐私与安全性 › 辅助功能"))
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
