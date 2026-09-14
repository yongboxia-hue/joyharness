import Foundation

/// The runtime's exit code for "another runtime already holds the lock".
///
/// Defined by the runtime, in src/process_guard.py. The contract check asserts
/// the two agree, because a drift here is silent: the app would describe a
/// duplicate launch as a crash and tell the user to restart something that is
/// already running.
let runtimeAlreadyRunningExitCode: Int32 = 3

@MainActor
final class RuntimeManager {
    private let state: AppState
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false

    init(state: AppState) {
        self.state = state
    }

    func startIfNeeded() {
        guard state.buildFlavor == "production" else { return }
        guard process?.isRunning != true else { return }

        do {
            let executable = try runtimeExecutableURL()
            let configURL = try prepareDataDirectory()
            let logsURL = state.runtimeURL.appendingPathComponent("Logs", isDirectory: true)
            let logURL = logsURL.appendingPathComponent("runtime.log")
            rotateLogIfLarge(at: logURL)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()

            try? FileManager.default.removeItem(at: state.ipcURL.appendingPathComponent("status.json"))
            let task = Process()
            task.executableURL = executable
            task.arguments = ["--native-client", "--no-admin-warn", "--config", configURL.path]
            task.currentDirectoryURL = state.runtimeURL
            var environment = ProcessInfo.processInfo.environment
            environment["JOYHARNESS_INPUT_BACKEND"] = "native"
            environment["JOYHARNESS_NATIVE_INPUT_SOCKET"] = state.ipcURL.appendingPathComponent("input.sock").path
            environment["JOYHARNESS_IPC_DIR"] = state.ipcURL.path
            task.environment = environment
            task.standardOutput = handle
            task.standardError = handle
            stopping = false
            task.terminationHandler = { [weak self, weak task] terminated in
                guard let self, let task else { return }
                Task { @MainActor in
                    guard self.process === task else { return }
                    self.process = nil
                    try? self.logHandle?.close()
                    self.logHandle = nil
                    if !self.stopping && terminated.terminationStatus != 0 {
                        self.state.lastError = Self.stopReason(for: terminated.terminationStatus)
                    }
                    self.state.refreshStatus()
                }
            }
            try task.run()
            process = task
            logHandle = handle
            state.reloadMappingConfiguration()
            state.refreshStatus()
        } catch {
            try? logHandle?.close()
            logHandle = nil
            state.lastError = "无法启动后台服务：\(error.localizedDescription)"
        }
    }

    func restart() {
        stop()
        startIfNeeded()
    }

    func stop() {
        guard let task = process else { return }
        stopping = true
        if task.isRunning {
            task.terminate()
            task.waitUntilExit()
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    /// Why the backend stopped, in terms the user can act on.
    ///
    /// Exit code 3 is the runtime refusing to start because another one
    /// already holds the lock. That is not a crash, and telling the user it
    /// stopped unexpectedly would send them to restart a service that is in
    /// fact already running -- which is what they would have been told before
    /// this existed.
    static func stopReason(for status: Int32) -> String {
        if status == runtimeAlreadyRunningExitCode {
            return "已经有一个 JoyHarness 后台服务在运行了。"
                + "如果手柄没有反应，请退出 JoyHarness 再重新打开。"
        }
        return "JoyHarness 意外停止了（代码 \(status)），可以在连接页重新启动。"
    }

    /// Start a fresh log once the current one gets big.
    ///
    /// The app appends every runtime's output to this file, so without this it
    /// grows without limit and mixes processes and dates together: the file
    /// that had to be read to diagnose the 2026-09-14 crash was 14MB of 181k
    /// lines spanning several days and two different builds. One previous file
    /// is kept, which is enough to cover a crash that happened just before a
    /// restart.
    private func rotateLogIfLarge(at logURL: URL) {
        let maximumBytes = 8 * 1024 * 1024
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? Int, size > maximumBytes else { return }
        let previousURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("runtime.previous.log")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
    }

    /// The bundled Python runtime for the architecture we are running on.
    ///
    /// The app binary is universal, but the runtime cannot be: hidapi ships
    /// separate arm64 and x86_64 wheels and no universal2 build, so
    /// PyInstaller produces one slice per architecture. Both are bundled,
    /// under Runtime/<arch>/, and the right one is chosen here.
    ///
    /// Note this is the *process* architecture, not the hardware's. Under
    /// Rosetta a universal app runs as x86_64 and must launch the x86_64
    /// runtime, so asking the CPU what it is would pick the wrong one.
    private func runtimeExecutableURL() throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw RuntimeManagerError.missingResources
        }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif

        let template = Bundle.main.object(forInfoDictionaryKey: "JoyHarnessRuntimeExecutable") as? String
            ?? "Runtime/{arch}/JoyHarnessRuntime/JoyHarnessRuntime"
        var candidates = [template.replacingOccurrences(of: "{arch}", with: architecture)]
        // A single-architecture build from before the universal layout.
        candidates.append("Runtime/JoyHarnessRuntime/JoyHarnessRuntime")

        for relativePath in candidates {
            let url = resourceURL.appendingPathComponent(relativePath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw RuntimeManagerError.missingRuntimeForArchitecture(architecture)
    }

    private func prepareDataDirectory() throws -> URL {
        let manager = FileManager.default
        let configDirectory = state.runtimeURL.appendingPathComponent("config", isDirectory: true)
        let logsDirectory = state.runtimeURL.appendingPathComponent("Logs", isDirectory: true)
        try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: state.ipcURL, withIntermediateDirectories: true)

        let destination = configDirectory.appendingPathComponent("user.json")
        guard let source = Bundle.main.url(forResource: "DefaultConfig", withExtension: "json") else {
            throw RuntimeManagerError.missingDefaultConfiguration
        }

        if !manager.fileExists(atPath: destination.path) {
            try manager.copyItem(at: source, to: destination)
            return destination
        }

        // An installed config is never touched again *except* when this build
        // ships a newer config_version. Without that check the very first
        // install's file lives forever: every later fix to the shipped
        // mappings reached the app bundle but never the file the runtime and
        // the mapping editor actually read, so the app kept running mappings
        // that no longer existed anywhere in the source tree.
        if configVersion(at: source) > configVersion(at: destination) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = configDirectory.appendingPathComponent("user-\(stamp).json.backup")
            try? manager.removeItem(at: backup)
            try manager.moveItem(at: destination, to: backup)
            try manager.copyItem(at: source, to: destination)
        }

        return destination
    }

    /// `config_version` from a config file, or 0 when absent -- which is what
    /// every pre-versioning config reads as, so those always get upgraded.
    private func configVersion(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["config_version"] as? Int else { return 0 }
        return version
    }
}

enum RuntimeManagerError: LocalizedError {
    case missingResources
    case missingRuntimeForArchitecture(String)
    case missingDefaultConfiguration

    var errorDescription: String? {
        switch self {
        case .missingResources:
            return "App 资源目录不完整。"
        case .missingRuntimeForArchitecture(let architecture):
            // 说清楚是哪一半缺了：装错架构的包是这里唯一会发生的事，
            // 而"找不到运行时"本身不足以让人知道该换哪个下载。
            return "这个安装包不包含 \(architecture) 版本的运行时，"
                + "请下载通用版本的 JoyHarness。"
        case .missingDefaultConfiguration:
            return "找不到默认按键配置。"
        }
    }
}
