import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private var stateSubscription: AnyCancellable?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = statusItemIcon
            button.image?.size = MenuBarIconRenderer.displaySize
            button.toolTip = state.statusSummary
        }
        updateAppearance()
        // `state` now only fires `objectWillChange` when a published value
        // actually changes (see AppState.refreshStatus), so reacting to it
        // replaces a Timer that redrew the icon every second forever, even
        // while idle. objectWillChange fires *before* the mutation lands, so
        // defer one runloop tick before reading the new value.
        stateSubscription = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateAppearance() }
            }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = buildMenu()
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            JoyHarnessAppDelegate.showMainWindow()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func updateAppearance() {
        guard let button = statusItem.button else { return }
        button.image = statusItemIcon
        button.image?.size = MenuBarIconRenderer.displaySize
        button.contentTintColor = nil
        button.toolTip = state.statusSummary
    }

    private var statusItemIcon: NSImage {
        let badge: MenuBarIconBadge
        switch state.availability {
        case .serviceStopped, .permissionRequired:
            badge = .warning
        case .paused:
            badge = .paused
        case .disconnected, .ready:
            badge = .none
        }
        return MenuBarIconRenderer.image(badge: badge)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: state.statusSummary, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let impact = NSMenuItem(title: state.availability.detail, action: nil, keyEquivalent: "")
        impact.isEnabled = false
        menu.addItem(impact)
        menu.addItem(.separator())

        menu.addItem(disabledItem(controllerTitle("左手柄", status: state.leftController)))
        menu.addItem(disabledItem(controllerTitle("右手柄", status: state.rightController)))
        menu.addItem(.separator())

        switch state.availability {
        case .serviceStopped:
            menu.addItem(actionItem("重新启动 JoyHarness", #selector(startService)))
        case .permissionRequired:
            menu.addItem(actionItem("去授权", #selector(openPermissions)))
        case .disconnected:
            menu.addItem(actionItem("打开蓝牙设置", #selector(openBluetooth)))
        case .paused:
            menu.addItem(actionItem("继续响应", #selector(togglePaused)))
        case .ready:
            menu.addItem(actionItem("暂停响应", #selector(togglePaused)))
        }

        menu.addItem(actionItem("打开主窗口", #selector(openMainWindow)))
        menu.addItem(actionItem("重新找一次手柄", #selector(refreshStatus)))
        menu.addItem(.separator())
        menu.addItem(actionItem("关于 JoyHarness", #selector(openAbout)))
        menu.addItem(actionItem("退出 JoyHarness", #selector(quitApp)))
        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Connection wording comes from ControllerStatus, the same place the two
    /// pages get it. This method used to derive its own and only knew two
    /// states, so a controller that had powered itself down after going idle
    /// read 未连接 here while the 连接 page said 已休眠 · 按任意键唤醒 -- about
    /// the feature most likely to send someone to the menu bar to check.
    private func controllerTitle(_ name: String, status: ControllerStatus) -> String {
        guard status.connected else { return "\(name)：\(status.statusText)" }
        guard let level = status.batteryLevel else { return "\(name)：已连接，电量读取中" }
        return status.charging ? "\(name)：电量 \(level)/4 · 充电中" : "\(name)：电量 \(level)/4"
    }

    @objc private func openMainWindow() {
        JoyHarnessAppDelegate.showMainWindow()
    }

    @objc private func openPermissions() {
        state.selectedPage = .about
        JoyHarnessAppDelegate.showMainWindow()
    }

    @objc private func openAbout() {
        state.selectedPage = .about
        JoyHarnessAppDelegate.showMainWindow()
    }

    @objc private func startService() { state.startService() }
    @objc private func togglePaused() { state.togglePaused() }
    @objc private func openBluetooth() { state.openBluetoothSettings() }
    @objc private func refreshStatus() { state.refreshStatus() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
