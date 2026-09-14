import Darwin
import Foundation

struct DiagnosticSnapshot: Sendable {
    let buildFlavor: String
    let runtimeURL: URL
    let ipcURL: URL
    let serviceRunning: Bool
    let paused: Bool
    let connectionMode: String
    let leftController: ControllerStatus
    let rightController: ControllerStatus
    let accessibilityGranted: Bool
    let launchAtLoginStatus: String
    let appearance: String
}

enum DiagnosticsExporter {
    static func export(snapshot: DiagnosticSnapshot, to destination: URL) throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JoyHarness-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let summary: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "build_flavor": snapshot.buildFlavor,
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": ProcessInfo.processInfo.machineArchitecture,
            "runtime_path": abbreviateHome(snapshot.runtimeURL.path),
            "service_running": snapshot.serviceRunning,
            "paused": snapshot.paused,
            "connection_mode": snapshot.connectionMode,
            "left_controller": controllerPayload(snapshot.leftController),
            "right_controller": controllerPayload(snapshot.rightController),
            "accessibility_granted": snapshot.accessibilityGranted,
            "launch_at_login": snapshot.launchAtLoginStatus,
            "appearance": snapshot.appearance
        ]
        try writeJSON(summary, to: root.appendingPathComponent("summary.json"))

        copyIfPresent(snapshot.ipcURL.appendingPathComponent("status.json"), to: root.appendingPathComponent("runtime-status.json"))
        copySanitizedConfig(from: snapshot.runtimeURL.appendingPathComponent("config/user.json"), to: root.appendingPathComponent("mapping-config.json"))
        copyLogTail(from: snapshot.runtimeURL.appendingPathComponent("logs/joyharness-app.log"), to: root.appendingPathComponent("runtime.log"))
        copyLogTail(from: snapshot.runtimeURL.appendingPathComponent("Logs/runtime.log"), to: root.appendingPathComponent("native-runtime.log"))

        try? manager.removeItem(at: destination)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, destination.path]
        let errorPipe = Pipe()
        task.standardError = errorPipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
            throw NSError(domain: "JoyHarness.Diagnostics", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func controllerPayload(_ status: ControllerStatus) -> [String: Any] {
        var payload: [String: Any] = [
            "connected": status.connected,
            "charging": status.charging
        ]
        payload["battery_level"] = status.batteryLevel.map { $0 as Any } ?? NSNull()
        return payload
    }

    private static func copySanitizedConfig(from source: URL, to destination: URL) {
        guard let data = try? Data(contentsOf: source),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        root.removeValue(forKey: "known_apps")
        root.removeValue(forKey: "selected_apps")
        try? writeJSON(root, to: destination)
    }

    private static func copyLogTail(from source: URL, to destination: URL) {
        guard let data = try? Data(contentsOf: source) else { return }
        let limit = 400_000
        let tail = data.count > limit ? data.suffix(limit) : data[...]
        guard let text = String(data: Data(tail), encoding: .utf8) else { return }
        let sensitiveTerms = ["authorization", "cookie", "password", "secret", "token"]
        let sanitized = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let lowercased = line.lowercased()
                return !sensitiveTerms.contains { lowercased.contains($0) }
            }
            .map { abbreviateHome(String($0)) }
            .joined(separator: "\n")
        try? Data((sanitized + "\n").utf8).write(to: destination, options: .atomic)
    }

    private static func copyIfPresent(_ source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private static func writeJSON(_ object: Any, to destination: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: destination, options: .atomic)
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { value, element in
            guard let byte = element.value as? Int8, byte != 0 else { return }
            value.append(Character(UnicodeScalar(UInt8(byte))))
        }
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var value = lhs
    value.append(rhs)
    return value
}
