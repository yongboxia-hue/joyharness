import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

enum SidebarPage: String, CaseIterable, Identifiable {
    case connection
    case mapping
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "连接"
        case .mapping: return "按键"
        case .settings: return "设置"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .connection: return "link"
        case .mapping: return "keyboard"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AvailabilityState: Equatable {
    case serviceStopped
    case permissionRequired
    case disconnected
    case paused
    case ready

    var title: String {
        switch self {
        case .serviceStopped: return "JoyHarness 暂时没有在运行"
        case .permissionRequired: return "还需要完成系统授权"
        case .disconnected: return "还没有连上手柄"
        case .paused: return "按键响应已暂停"
        case .ready: return "已就绪"
        }
    }

    var badge: String {
        switch self {
        case .serviceStopped: return "服务异常"
        case .permissionRequired: return "需要授权"
        case .disconnected: return "未连接"
        case .paused: return "已暂停"
        case .ready: return "已就绪"
        }
    }

    var detail: String {
        switch self {
        case .serviceStopped:
            return "手柄按了没反应。你的配置都还在。"
        case .permissionRequired:
            return "先在系统里授权，JoyHarness 才能替你按键盘。"
        case .disconnected:
            return "在系统蓝牙设置里连上任意一只手柄就能用。"
        case .paused:
            return "手柄还连着，只是暂时不动作。"
        case .ready:
            return "现在按手柄，Mac 就有反应。"
        }
    }

    var symbol: String {
        switch self {
        case .serviceStopped: return "exclamationmark.triangle.fill"
        case .permissionRequired: return "lock.trianglebadge.exclamationmark"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .paused: return "pause.fill"
        case .ready: return "checkmark"
        }
    }

    var tint: NSColor {
        switch self {
        case .serviceStopped, .permissionRequired: return .systemRed
        case .disconnected: return .secondaryLabelColor
        case .paused: return .systemOrange
        case .ready: return .systemGreen
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedPage: SidebarPage = .connection
    @Published var serviceRunning = false
    @Published var paused = false
    @Published var connectionMode = "none"
    @Published var leftController = ControllerStatus()
    @Published var rightController = ControllerStatus()
    @Published var accessibilityGranted = false
    /// Minutes of no input before a controller is asked to power down.
    /// Zero means never, which is the shipped default.
    @Published private(set) var idleSleepMinutes: Double = 0
    /// How long a press has to last to count as 长按, read from the same config
    /// file the runtime reads so the UI and the behaviour cannot disagree.
    @Published private(set) var longPressThreshold: Double = 0.35
    @Published private(set) var isSavingIdleSleep = false
    @Published var lastError: String?
    @Published var isPerformingServiceAction = false
    @Published var isChangingPauseState = false
    @Published var launchAtLogin = false
    @Published var launchAtLoginStatus = "未开启"
    @Published var launchAtLoginDetail = "登录 Mac 后自动启动，无需手动打开。"
    @Published var launchAtLoginRequiresApproval = false
    @Published var isUpdatingLaunchAtLogin = false
    @Published var appearance: AppAppearance = .system
    @Published var mappingConfiguration = MappingConfiguration.empty
    @Published var mappingConfigError: String?
    @Published var mappingDraft: MappingEditDraft?
    @Published var isSavingMapping = false
    @Published var mappingSide: ControllerSide = .right {
        didSet { mappingSideWasChosen = true }
    }
    /// Set once the user picks a side by hand, after which the connection no
    /// longer moves it under them.
    private var mappingSideWasChosen = false
    @Published var isRefreshingStatus = false
    @Published var isShowingOnboarding = false { didSet { syncOnboardingOutputHold() } }
    @Published var onboardingStep = 0 { didSet { syncOnboardingOutputHold() } }
    /// What `paused` was before onboarding took over, so leaving the test puts
    /// it back rather than assuming it was running.
    private var pausedBeforeOnboarding: Bool?
    @Published private(set) var onboardingWorkflowProgress: Set<String> = []
    @Published var isExportingDiagnostics = false

    let runtimeURL: URL
    let ipcURL: URL
    let buildFlavor: String

    private var refreshTimer: Timer?
    private let runtimeClient: RuntimeClient
    private let configStore: ConfigStore
    private var latestInputSequence = 0
    private var onboardingInputBaseline = 0
    private var onboardingPressTimes: [String: TimeInterval] = [:]
    private static let appearanceDefaultsKey = "JoyHarnessAppearance"
    private static let onboardingDefaultsKey = "JoyHarnessOnboardingVersion"
    private static let onboardingVersion = 2

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let configuredRuntime = info["JoyHarnessRuntimePath"] as? String
        let runtimePath = configuredRuntime?.expandingTildeInPath
            ?? "~/Applications/JoyHarness".expandingTildeInPath
        let runtimeLocation = URL(fileURLWithPath: runtimePath, isDirectory: true)
        let configuredIPC = info["JoyHarnessIPCPath"] as? String
        let ipcPath = configuredIPC?.expandingTildeInPath
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("joyharness-runtime", isDirectory: true).path
        let ipcLocation = URL(fileURLWithPath: ipcPath, isDirectory: true)
        runtimeURL = runtimeLocation
        ipcURL = ipcLocation
        buildFlavor = info["JoyHarnessBuildFlavor"] as? String ?? "preview"
        let client = RuntimeClient(ipcURL: ipcLocation)
        runtimeClient = client
        configStore = ConfigStore(
            configURL: runtimeLocation.appendingPathComponent("config/user.json"),
            runtimeClient: client
        )
        appearance = AppAppearance(
            rawValue: UserDefaults.standard.string(forKey: Self.appearanceDefaultsKey) ?? "system"
        ) ?? .system
        let forceOnboarding = ProcessInfo.processInfo.environment["JOYHARNESS_FORCE_ONBOARDING"] == "1"
        isShowingOnboarding = forceOnboarding || (
            buildFlavor == "production"
                && UserDefaults.standard.integer(forKey: Self.onboardingDefaultsKey) < Self.onboardingVersion
        )

        refreshStatus()
        refreshPermissions()
        refreshLaunchAtLogin()
        reloadMappingConfiguration()
        // Authorization is polled alongside the runtime status. Granting it
        // happens in System Settings, outside this app, so there is no event
        // to react to -- and making the user come back and press 重新检查 to
        // find out whether their own grant worked is not a check, it is a
        // chore.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshStatus()
                self.refreshPermissions()
            }
        }
    }

    var availability: AvailabilityState {
        if !serviceRunning { return .serviceStopped }
        if !permissionsSatisfied { return .permissionRequired }
        if !leftController.connected && !rightController.connected { return .disconnected }
        if paused { return .paused }
        return .ready
    }

    var permissionsSatisfied: Bool {
        accessibilityGranted
    }

    var controllerSummary: String {
        if leftController.connected && rightController.connected { return "左右手柄都连上了" }
        if leftController.connected { return "左手柄已连接" }
        if rightController.connected { return "右手柄已连接" }
        return "没有找到手柄"
    }

    var statusSummary: String {
        "JoyHarness · \(availability.badge)"
    }

    var appIcon: NSImage? {
        imageResource(named: "JoyHarnessAppIcon")
    }

    func imageResource(named name: String) -> NSImage? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    /// Polled once a second by `refreshTimer`. Only writes to `@Published`
    /// properties that actually changed, so idling (the common case — no
    /// Joy-Con activity) doesn't trigger a Combine `objectWillChange` and a
    /// SwiftUI re-render of every observing view once a second forever.
    /// How old status.json may be before it stops counting as the truth.
    ///
    /// The runtime rewrites it about twice a second, and writes running=false
    /// on a clean exit -- but a crash or a kill leaves the last healthy file
    /// sitting there saying everything is fine. Trusting it meant the app
    /// went on reporting 已就绪, both controllers connected and 正在响应 long
    /// after nothing was reading the Joy-Cons at all, which is the same
    /// failure as a reader spinning on a dead HID handle: stale state
    /// mistaken for live state.
    private static let statusFreshness: TimeInterval = 4

    /// So the "unreadable status" note is written once per episode rather than
    /// twice a second for as long as it lasts.
    private var hasReportedUnreadableStatus = false

    func refreshStatus() {
        let statusURL = ipcURL.appendingPathComponent("status.json")
        let writtenAt = (try? statusURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let stale = writtenAt.map { Date().timeIntervalSince($0) > Self.statusFreshness } ?? true

        // A file that exists and is fresh but will not parse is not the same
        // thing as a service that is not running, and reporting it as one sent
        // the user to the restart button for a runtime that was alive. Say so
        // instead, once, so the next diagnostic package carries the reason.
        if !stale,
           let data = try? Data(contentsOf: statusURL),
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            if !hasReportedUnreadableStatus {
                hasReportedUnreadableStatus = true
                NSLog("JoyHarness: status.json is fresh but unreadable (\(data.count) bytes)")
                lastError = "JoyHarness 读不到自己的状态。退出再打开一次，通常就好了。"
            }
        } else if hasReportedUnreadableStatus {
            hasReportedUnreadableStatus = false
        }

        guard
            !stale,
            let data = try? Data(contentsOf: statusURL),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if serviceRunning { serviceRunning = false }
            if leftController != ControllerStatus() { leftController = ControllerStatus() }
            if rightController != ControllerStatus() { rightController = ControllerStatus() }
            if connectionMode != "none" { connectionMode = "none" }
            return
        }

        let running = (payload["running"] as? Bool) ?? false
        if serviceRunning != running { serviceRunning = running }
        let isPaused = (payload["paused"] as? Bool) ?? false
        if paused != isPaused { paused = isPaused }
        let mode = (payload["connection_mode"] as? String) ?? "none"
        if connectionMode != mode { connectionMode = mode }
        let battery = payload["battery"] as? [String: Any] ?? [:]
        let left = ControllerStatusParser.parse(battery["L"])
        if leftController != left { leftController = left }
        let right = ControllerStatusParser.parse(battery["R"])
        if rightController != right { rightController = right }
        followConnectedControllerIfUnchosen()
        processOnboardingInputEvents(RuntimeInputEvent.parse(payload["input_events"]))
    }

    /// Open the 按键 page on the controller that is actually in the user's
    /// hand. Only while they have not chosen a side themselves -- once they
    /// have, the page stays where they put it.
    private func followConnectedControllerIfUnchosen() {
        guard !mappingSideWasChosen else { return }
        let connected: ControllerSide?
        switch (leftController.connected, rightController.connected) {
        case (true, false): connected = .left
        case (false, true): connected = .right
        default: connected = nil
        }
        guard let connected, connected != mappingSide else { return }
        let chosen = mappingSideWasChosen
        mappingSide = connected
        mappingSideWasChosen = chosen
    }

    /// Which side the 连接 page summarises: the one that is connected, and the
    /// right one when both or neither are. Named here so the page can say so
    /// rather than leaving the reader to guess which hand it means.
    var previewSide: ControllerSide {
        leftController.connected && !rightController.connected ? .left : .right
    }

    func refreshStatusWithFeedback() {
        guard !isRefreshingStatus else { return }
        isRefreshingStatus = true
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.isRefreshingStatus = false
        }
    }

    /// Polled once a second, so it must not write unless the answer changed:
    /// assigning to a @Published property fires objectWillChange whether or
    /// not the value differs, which would re-render every observing view once
    /// a second for as long as the app is open.
    var idleSleepEnabled: Bool { idleSleepMinutes > 0 }

    /// Default when switching it on. Long enough that a pause to read or think
    /// does not drop the controller, short enough to matter over a workday.
    private static let defaultIdleSleepMinutes: Double = 10

    func setIdleSleep(enabled: Bool) {
        guard !isSavingIdleSleep else { return }
        isSavingIdleSleep = true
        let minutes = enabled ? Self.defaultIdleSleepMinutes : 0
        Task {
            do {
                var root = try await configStore.loadJSONObject()
                root["idle_sleep_minutes"] = minutes
                try await configStore.save(root)
                idleSleepMinutes = minutes
            } catch {
                lastError = "休眠设置没保存上：\(error.localizedDescription)"
            }
            isSavingIdleSleep = false
        }
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane(anchor: "Privacy_Accessibility")
        refreshPermissionsSoon()
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The button test asks the user to press keys, and those keys are mapped
    /// to real shortcuts -- so without this, following the instructions also
    /// fired fn, pasted, or sent a message. Detection is unaffected: the
    /// reader records every press before handing it to the mapper, and only
    /// the mapper honours the pause.
    private func syncOnboardingOutputHold() {
        let shouldHold = isShowingOnboarding && onboardingStep == Self.onboardingButtonTestStep
        if shouldHold {
            guard pausedBeforeOnboarding == nil else { return }
            pausedBeforeOnboarding = paused
            guard !paused else { return }
            setPausedForOnboarding(true)
        } else {
            guard let previous = pausedBeforeOnboarding else { return }
            pausedBeforeOnboarding = nil
            guard !previous else { return }
            setPausedForOnboarding(false)
        }
    }

    private func setPausedForOnboarding(_ value: Bool) {
        Task {
            do {
                try await runtimeClient.holdOutput(value)
            } catch {
                // Not worth an error banner over the onboarding sheet; the
                // worst case is that the practice presses also take effect,
                // which is what used to happen every time.
                NSLog("JoyHarness: could not hold output during onboarding: %@",
                      error.localizedDescription)
            }
        }
    }

    func togglePaused() {
        guard serviceRunning, !isChangingPauseState else { return }
        let requestedState = !paused
        isChangingPauseState = true
        Task {
            do {
                let confirmedState = try await runtimeClient.setPaused(requestedState)
                paused = confirmedState
                refreshStatusSoon()
            } catch {
                lastError = "没能切换：\(error.localizedDescription)"
            }
            isChangingPauseState = false
        }
    }

    func startService() {
        if buildFlavor == "production" {
            JoyHarnessAppDelegate.startRuntime()
        } else {
            runRuntimeScript(named: "start-joyharness.sh")
        }
    }

    func restartService() {
        if buildFlavor == "production" {
            JoyHarnessAppDelegate.restartRuntime()
        } else {
            runRuntimeScript(named: "restart-joyharness-authorized.sh")
        }
    }

    func revealRuntime() {
        NSWorkspace.shared.activateFileViewerSelecting([runtimeURL])
    }

    func refreshLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            launchAtLogin = false
            launchAtLoginStatus = "系统不支持"
            launchAtLoginDetail = "需要 macOS 13 或更高版本。"
            launchAtLoginRequiresApproval = false
            return
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginRequiresApproval = status == .requiresApproval
        switch status {
        case .enabled:
            launchAtLoginStatus = "已开启"
            launchAtLoginDetail = "登录 Mac 后自动启动，无需手动打开。"
        case .requiresApproval:
            launchAtLoginStatus = "等待确认"
            launchAtLoginDetail = "去「系统设置 → 通用 → 登录项」里允许 JoyHarness。"
        // .notFound is what a never-registered app reads as: launchd has no
        // record to look up yet, which is indistinguishable from "off" and is
        // fixed by the very toggle this row carries. Reporting it as 当前不可用
        // and telling the user to move the app into Applications sent every new
        // install chasing something they had already done, about a feature that
        // worked -- flipping the switch registers it first time.
        case .notRegistered, .notFound:
            launchAtLoginStatus = "未开启"
            launchAtLoginDetail = "开启后，登录 Mac 时会自动启动 JoyHarness。"
        @unknown default:
            launchAtLoginStatus = "状态未知"
            launchAtLoginDetail = "读不到系统里的设置，稍后再试。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *), !isUpdatingLaunchAtLogin else { return }
        isUpdatingLaunchAtLogin = true
        defer { isUpdatingLaunchAtLogin = false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            lastError = "没能改成功：\(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.appearanceDefaultsKey)
        applyAppearance()
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    func dismissError() {
        lastError = nil
    }

    func showOnboarding() {
        onboardingStep = 0
        isShowingOnboarding = true
        refreshPermissions()
        refreshStatus()
        beginOnboardingWorkflowMonitoring()
    }

    /// The step that asks the user to press buttons.
    static let onboardingButtonTestStep = 3

    /// The button test, read from the mappings that are actually installed.
    ///
    /// This used to be a table in OnboardingView saying ZR is fn and + is ⌘V.
    /// It happened to be right, but only because nobody had changed the
    /// defaults yet -- reopen the walkthrough after remapping a button and it
    /// would confidently teach the old shortcut. Same reason the 连接 summary
    /// stopped carrying its own button table.
    var onboardingChecks: [OnboardingCheck] {
        let side: ControllerSide = leftController.connected && !rightController.connected ? .left : .right
        let cards = mappingCards(for: side)
        // Both sides mirror by position, so the left hand's ZL/− stand in for
        // the right hand's ZR/+.
        let trigger = side == .left ? "ZL" : "ZR"
        let modifier = side == .left ? "Minus" : "Plus"

        func check(_ id: String, _ button: String, gesture: String?, long: Bool) -> OnboardingCheck? {
            guard let card = cards.first(where: { $0.id == button }) else { return nil }
            var row = card.rows.first
            if let gesture {
                row = card.rows.first(where: { $0.gesture == gesture })
            }
            guard let row, row.value != "未设置" else { return nil }
            return OnboardingCheck(
                id: id, button: button, isLongPress: long, key: card.key, shortcut: row.value
            )
        }

        return [
            check("fn", trigger, gesture: nil, long: false),
            check("paste", modifier, gesture: "单击", long: false),
            check("dictation", modifier, gesture: "长按", long: true),
            check("enter", "A", gesture: "单击", long: false) ?? check("enter", "A", gesture: nil, long: false)
        ].compactMap { $0 }
    }

    /// Derived, not stored: the test is done when every check it is showing has
    /// happened. Storing a count meant the "four presses" in the detector and
    /// the four rows on screen were two separate facts.
    var onboardingWorkflowConfirmed: Bool {
        let checks = onboardingChecks
        return !checks.isEmpty && checks.allSatisfy { onboardingWorkflowProgress.contains($0.id) }
    }

    func beginOnboardingWorkflowMonitoring() {
        onboardingWorkflowProgress = []
        onboardingInputBaseline = latestInputSequence
        onboardingPressTimes.removeAll()
    }

    func onboardingWorkflowHas(_ item: String) -> Bool {
        onboardingWorkflowProgress.contains(item)
    }

    private func processOnboardingInputEvents(_ events: [RuntimeInputEvent]) {
        // A restarting runtime numbers its events from one again, so a sequence
        // lower than what we have already seen means "new process", not "old
        // event". Without this the baseline stayed at the old high-water mark
        // and the button test could never be satisfied again in this session.
        if let highest = events.map(\.sequence).max(), highest < latestInputSequence {
            latestInputSequence = 0
            onboardingInputBaseline = 0
            onboardingPressTimes.removeAll()
        }

        guard isShowingOnboarding, onboardingStep == Self.onboardingButtonTestStep else {
            latestInputSequence = max(latestInputSequence, events.map(\.sequence).max() ?? latestInputSequence)
            return
        }

        // Either controller can run the test. The two sides mirror each other
        // by position, so the same four checks map onto ZR/Plus/A on the right
        // and ZL/Minus/A on the left -- keying only off the right-hand names
        // meant a left-only user could never finish onboarding.
        for event in events where event.sequence > onboardingInputBaseline {
            latestInputSequence = max(latestInputSequence, event.sequence)
            if event.phase == "down" {
                onboardingPressTimes[event.button] = event.timestamp
                continue
            }
            guard event.phase == "up", let startedAt = onboardingPressTimes.removeValue(forKey: event.button) else {
                continue
            }
            let duration = max(0, event.timestamp - startedAt)
            // The checks on screen decide what counts, and the threshold comes
            // from the config the runtime splits on -- so what the user is told
            // to press, what satisfies it, and what actually fires are one fact.
            let candidates = onboardingChecks.filter { $0.button == event.button }
            let wasLong = duration >= longPressThreshold
            let match = candidates.first { $0.isLongPress == wasLong }
                ?? (candidates.count == 1 ? candidates.first : nil)
            if let match {
                onboardingWorkflowProgress.insert(match.id)
            }
        }
    }

    /// Closing the walkthrough -- by finishing it or by choosing 稍后设置 --
    /// records that this version has been shown, so it stops opening itself.
    ///
    /// It used to record only on the last step, and the last step cannot be
    /// reached without the Accessibility grant *and* a paired controller *and*
    /// four real button presses. Anyone who did not have all three got the
    /// full-window walkthrough again at every launch, which for a login item
    /// means at every login. 关于 → 首次使用引导 → 重新查看 is the way back in.
    func dismissOnboarding(markCompleted: Bool = true) {
        if markCompleted {
            UserDefaults.standard.set(Self.onboardingVersion, forKey: Self.onboardingDefaultsKey)
        }
        isShowingOnboarding = false
        selectedPage = .connection
    }

    func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        let panel = NSSavePanel()
        panel.title = "导出 JoyHarness 诊断包"
        panel.nameFieldStringValue = "JoyHarness-Diagnostics-\(Self.diagnosticDate()).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExportingDiagnostics = true
        let snapshot = DiagnosticSnapshot(
            buildFlavor: buildFlavor,
            runtimeURL: runtimeURL,
            ipcURL: ipcURL,
            serviceRunning: serviceRunning,
            paused: paused,
            connectionMode: connectionMode,
            leftController: leftController,
            rightController: rightController,
            accessibilityGranted: accessibilityGranted,
            launchAtLoginStatus: launchAtLoginStatus,
            appearance: appearance.rawValue
        )
        Task.detached {
            do {
                try DiagnosticsExporter.export(snapshot: snapshot, to: destination)
                await MainActor.run {
                    self.isExportingDiagnostics = false
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                await MainActor.run {
                    self.isExportingDiagnostics = false
                    self.lastError = "排查文件没能导出：\(error.localizedDescription)"
                }
            }
        }
    }

    func mappingCards(for side: ControllerSide) -> [MappingCardModel] {
        mappingConfiguration.cardsBySide[side] ?? []
    }

    func reloadMappingConfiguration() {
        let url = runtimeURL.appendingPathComponent("config/user.json")
        // The toggle reads from the same file the runtime does, so it shows
        // what is actually in effect rather than a separately held copy.
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            idleSleepMinutes = (root["idle_sleep_minutes"] as? NSNumber)?.doubleValue ?? 0
            longPressThreshold = (root["long_press_threshold"] as? NSNumber)?.doubleValue ?? 0.35
        }
        do {
            mappingConfiguration = try MappingConfigReader.load(from: url)
            mappingConfigError = nil
        } catch {
            mappingConfiguration = .empty
            mappingConfigError = "读不到当前的按键配置：\(error.localizedDescription)"
        }
    }

    func beginEditing(side: ControllerSide, button: String, displayKey: String? = nil) {
        Task {
            do {
                let root = try await configStore.loadJSONObject()
                mappingDraft = draft(from: root, side: side, button: button, displayKey: displayKey)
            } catch {
                lastError = "打不开按键配置：\(error.localizedDescription)"
            }
        }
    }

    /// Reports failure back to the editor sheet rather than through
    /// `lastError`.
    ///
    /// The root alert cannot appear over an open sheet, so a save that failed
    /// looked like nothing happening at all: the button went back to 保存, the
    /// sheet stayed open, and the explanation only surfaced once the user gave
    /// up and pressed 取消.
    func saveMapping(_ draft: MappingEditDraft, completion: @escaping (String?) -> Void) {
        guard !isSavingMapping else { return }
        isSavingMapping = true
        Task {
            do {
                var root = try await configStore.loadJSONObject()
                try apply(draft, to: &root)
                try await configStore.save(root)
                reloadMappingConfiguration()
                mappingDraft = nil
                completion(nil)
            } catch {
                completion("没保存上：\(error.localizedDescription)")
            }
            isSavingMapping = false
        }
    }

    /// "恢复推荐" restores what this build ships as the default for that
    /// button, read from the bundled config itself.
    ///
    /// It used to be a second table written out in Swift, which drifted:
    /// it still held the left controller's pre-correction mappings long
    /// after config/user.json had been fixed, so restoring a left-hand
    /// button handed back a mapping that no config file contained.
    func recommendedDraft(side: ControllerSide, button: String, displayKey: String? = nil) -> MappingEditDraft {
        let shipped = Self.shippedDefaults()
        return draft(
            from: shipped,
            side: side,
            button: button,
            displayKey: displayKey
        )
    }

    private static func shippedDefaults() -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "DefaultConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return root
    }

    private func draft(from root: [String: Any], side: ControllerSide, button: String, displayKey: String?) -> MappingEditDraft {
        let mapping = buttonMapping(root, side: side, button: button)
        let action = mapping?["action"] as? String
        var single: [String: Any]? = mapping
        var double: [String: Any]?
        var long: [String: Any]?
        if action == "double_tap" { single = mapping?["single"] as? [String: Any]; double = mapping?["double"] as? [String: Any] }
        if action == "short_long" { single = mapping?["short"] as? [String: Any]; long = mapping?["long"] as? [String: Any] }
        if action == "multi_trigger" { single = mapping?["tap"] as? [String: Any]; double = mapping?["double"] as? [String: Any]; long = mapping?["hold"] as? [String: Any] }
        return MappingEditDraft(
            side: side,
            button: button,
            displayKey: displayKey ?? displayButton(button),
            single: .from(single),
            double: .from(double),
            long: .from(long)
        )
    }

    private func buttonMapping(_ root: [String: Any], side: ControllerSide, button: String) -> [String: Any]? {
        let profiles = root["profiles"] as? [String: Any]
        let profile = profiles?[side.profileName] as? [String: Any]
        let mappings = profile?["mappings"] as? [String: Any]
        let buttons = mappings?["buttons"] as? [String: Any]
        return buttons?[button] as? [String: Any]
    }

    private func apply(_ draft: MappingEditDraft, to root: inout [String: Any]) throws {
        guard var profiles = root["profiles"] as? [String: Any],
              var profile = profiles[draft.side.profileName] as? [String: Any],
              var mappings = profile["mappings"] as? [String: Any],
              var buttons = mappings["buttons"] as? [String: Any] else {
            throw ConfigStoreError.missingProfile(draft.side.profileName)
        }
        // The shape of what gets written is decided by how many gestures the
        // user actually filled in -- there is no separate "type" to pick.
        // One gesture means the button simply *is* that key (passthrough);
        // adding a second turns it into a split, which is also the moment
        // its first gesture starts firing on release instead of on press.
        let double = draft.double.slotMapping
        let long = draft.long.slotMapping
        let output: [String: Any]
        if double == nil && long == nil {
            output = draft.single.passthroughMapping ?? ["action": "disabled"]
        } else if long == nil {
            output = ["action": "double_tap",
                      "single": draft.single.slotMapping ?? ["action": "disabled"],
                      "double": double!]
        } else if double == nil {
            // No per-button "threshold": leaving it out means the button uses
            // the profile's long_press_threshold, so there is one number in the
            // product rather than a fresh copy stamped into every button the
            // editor touches.
            output = ["action": "short_long",
                      "short": draft.single.slotMapping ?? ["action": "disabled"],
                      "long": long!]
        } else {
            output = ["action": "multi_trigger",
                      "tap": draft.single.slotMapping ?? ["action": "disabled"],
                      "double": double!, "hold": long!]
        }
        buttons[draft.button] = output
        mappings["buttons"] = buttons
        profile["mappings"] = mappings
        profiles[draft.side.profileName] = profile
        root["profiles"] = profiles
    }

    private func displayButton(_ button: String) -> String {
        ["Plus": "+", "Minus": "−", "RStick": "摇杆", "LStick": "摇杆", "Capture": "截图"][button] ?? button
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshPermissionsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshPermissions()
        }
    }

    private func refreshStatusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.refreshStatus()
        }
    }

    private func runRuntimeScript(named name: String) {
        guard !isPerformingServiceAction else { return }
        let scriptURL = runtimeURL.appendingPathComponent("scripts/\(name)")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            lastError = "JoyHarness 少了一个组件，可能是没装全。重新安装一次。"
            return
        }

        isPerformingServiceAction = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        task.currentDirectoryURL = runtimeURL
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.terminationHandler = { [weak self] process in
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self else { return }
            Task { @MainActor in
                self.isPerformingServiceAction = false
                if process.terminationStatus != 0 {
                    self.lastError = message?.isEmpty == false
                        ? message
                        : "这一步没能完成，稍后再试。"
                }
                self.refreshStatusSoon()
            }
        }

        do {
            try task.run()
        } catch {
            isPerformingServiceAction = false
            lastError = "这一步没能开始：\(error.localizedDescription)"
        }
    }

    private static func diagnosticDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private extension String {
    var expandingTildeInPath: String {
        NSString(string: self).expandingTildeInPath
    }
}
