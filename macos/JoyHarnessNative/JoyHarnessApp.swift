import AppKit
import SwiftUI

@main
enum JoyHarnessMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = JoyHarnessAppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) { }
    }
}

@MainActor
final class JoyHarnessAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static weak var current: JoyHarnessAppDelegate?
    private var statusBarController: StatusBarController?
    private var mainWindow: NSWindow?
    private var inputGateway: InputGateway?
    private var runtimeManager: RuntimeManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        NSApp.setActivationPolicy(.accessory)
        configureApplicationMenu()
        configureMainWindow()
        AppState.shared.applyAppearance()
        statusBarController = StatusBarController(state: .shared)
        configureInputGateway()
        configureRuntimeManager()
        AppState.shared.refreshStatus()
        AppState.shared.refreshPermissions()
        DispatchQueue.main.async {
            Self.showMainWindow()
        }
        if AppState.shared.buildFlavor == "preview" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.capturePreviewPagesForQA(index: 0)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtimeManager?.stop()
        inputGateway?.stop()
    }

    static func showMainWindow() {
        current?.showMainWindow()
    }

    static func startRuntime() {
        current?.runtimeManager?.startIfNeeded()
    }

    static func restartRuntime() {
        current?.runtimeManager?.restart()
    }

    private func configureMainWindow() {
        let root = RootView()
            .environmentObject(AppState.shared)
            .frame(minWidth: 980, minHeight: 650)
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "JoyHarness"
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.minSize = NSSize(width: 980, height: 650)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        mainWindow = window
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 JoyHarness", action: #selector(openAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 JoyHarness", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 JoyHarness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureInputGateway() {
        // Unlike RuntimeManager (which owns spawning a real background
        // daemon and stays production-only so Preview builds don't launch
        // a second one automatically), this only opens a local socket and
        // does nothing until something connects to it -- there's no reason
        // for Preview's manual "启动服务" path to talk to a different,
        // unmaintained keyboard-synthesis implementation than production.
        let gateway = InputGateway(socketURL: AppState.shared.ipcURL.appendingPathComponent("input.sock"))
        do {
            try gateway.start()
            inputGateway = gateway
        } catch {
            AppState.shared.lastError = "无法启动原生按键输出服务：\(error.localizedDescription)"
        }
    }

    private func configureRuntimeManager() {
        let manager = RuntimeManager(state: .shared)
        runtimeManager = manager
        manager.startIfNeeded()
    }

    @objc private func openAbout() {
        AppState.shared.selectedPage = .about
        showMainWindow()
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    private func capturePreviewPagesForQA(index: Int) {
        let pages = SidebarPage.allCases
        guard index < pages.count else {
            captureDarkSupportPages(index: 0)
            return
        }
        let page = pages[index]
        AppState.shared.selectedPage = page
        if page == .mapping { AppState.shared.mappingSide = .right }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.capturePreviewWindowForQA(name: page.rawValue)
            if page == .mapping {
                AppState.shared.mappingSide = .left
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.capturePreviewWindowForQA(name: "mapping-left")
                    AppState.shared.mappingSide = .right
                    self?.mainWindow?.appearance = NSAppearance(named: .darkAqua)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        self?.capturePreviewWindowForQA(name: "mapping-dark")
                        AppState.shared.mappingSide = .left
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                            self?.capturePreviewWindowForQA(name: "mapping-left-dark")
                            AppState.shared.mappingSide = .right
                            self?.mainWindow?.appearance = nil
                            self?.capturePreviewPagesForQA(index: index + 1)
                        }
                    }
                }
            } else {
                self?.capturePreviewPagesForQA(index: index + 1)
            }
        }
    }

    private func captureDarkSupportPages(index: Int) {
        let pages: [SidebarPage] = [.connection, .mapping, .about]
        guard index < pages.count else {
            mainWindow?.appearance = nil
            AppState.shared.selectedPage = .mapping
            AppState.shared.mappingSide = .right
            AppState.shared.beginEditing(side: .right, button: "ZR")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.capturePreviewWindowForQA(name: "mapping-editor", window: NSApp.keyWindow)
                AppState.shared.mappingDraft = nil
                AppState.shared.selectedPage = .connection
            }
            return
        }
        mainWindow?.appearance = NSAppearance(named: .darkAqua)
        let page = pages[index]
        AppState.shared.selectedPage = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.capturePreviewWindowForQA(name: "\(page.rawValue)-dark")
            self?.captureDarkSupportPages(index: index + 1)
        }
    }

    private func capturePreviewWindowForQA(name: String, window: NSWindow? = nil) {
        guard let view = (window ?? mainWindow)?.contentView else { return }
        let bounds = view.bounds
        guard
            bounds.width > 0,
            bounds.height > 0,
            let representation = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return }
        view.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("joyharness-preview-\(name).png")
        try? data.write(to: outputURL, options: .atomic)
    }
}
