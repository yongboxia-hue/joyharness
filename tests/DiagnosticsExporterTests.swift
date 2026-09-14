import Foundation

@main
enum DiagnosticsExporterTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("joyharness-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let ipc = root.appendingPathComponent("ipc", isDirectory: true)
        let config = runtime.appendingPathComponent("config", isDirectory: true)
        let logs = runtime.appendingPathComponent("Logs", isDirectory: true)
        let archive = root.appendingPathComponent("diagnostics.zip")
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        try manager.createDirectory(at: config, withIntermediateDirectories: true)
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        try manager.createDirectory(at: ipc, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try expect(
            ControllerStatusParser.parse(["disconnected", -1]) == ControllerStatus(),
            "disconnected runtime state was interpreted as connected"
        )
        try expect(
            ControllerStatusParser.parse(["connected", -1]) == ControllerStatus(connected: true),
            "explicit connected runtime state was not accepted"
        )
        try expect(
            ControllerStatusParser.parse(["charging", 3]) == ControllerStatus(connected: true, batteryLevel: 3, charging: true),
            "charging runtime state was not parsed"
        )

        try encoded([
            "known_apps": ["Private App"],
            "selected_apps": ["Private App"],
            "profiles": ["single_left": [:], "single_right": [:]]
        ]).write(to: config.appendingPathComponent("user.json"))
        try encoded(["running": true]).write(to: ipc.appendingPathComponent("status.json"))
        let home = manager.homeDirectoryForCurrentUser.path
        try Data("opened \(home)/Documents/file\nauthorization: private-value\nhealthy\n".utf8)
            .write(to: logs.appendingPathComponent("runtime.log"))

        let snapshot = DiagnosticSnapshot(
            buildFlavor: "production",
            runtimeURL: runtime,
            ipcURL: ipc,
            serviceRunning: true,
            paused: false,
            connectionMode: "single_right",
            leftController: ControllerStatus(),
            rightController: ControllerStatus(connected: true, batteryLevel: nil, charging: false),
            accessibilityGranted: true,
            launchAtLoginStatus: "enabled",
            appearance: "system"
        )
        try DiagnosticsExporter.export(snapshot: snapshot, to: archive)
        try manager.createDirectory(at: expanded, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", archive.path, expanded.path])

        let files = try manager.subpathsOfDirectory(atPath: expanded.path)
        let packageRoot = try requireFile(named: "summary.json", in: files, expanded: expanded).deletingLastPathComponent()
        let summary = try json(at: packageRoot.appendingPathComponent("summary.json"))
        let right = summary["right_controller"] as? [String: Any]
        try expect(right?["battery_level"] is NSNull, "nil battery was not encoded as null")

        let mapping = try json(at: packageRoot.appendingPathComponent("mapping-config.json"))
        try expect(mapping["known_apps"] == nil, "known_apps leaked into diagnostics")
        try expect(mapping["selected_apps"] == nil, "selected_apps leaked into diagnostics")

        let log = try String(contentsOf: packageRoot.appendingPathComponent("native-runtime.log"), encoding: .utf8)
        try expect(!log.contains(home), "home directory was not abbreviated")
        try expect(!log.lowercased().contains("authorization"), "sensitive log line was not removed")
        try expect(log.contains("~/Documents/file") && log.contains("healthy"), "safe log context was lost")
        print("Diagnostics export and redaction tests passed.")
    }

    private static func encoded(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private static func requireFile(named name: String, in files: [String], expanded: URL) throws -> URL {
        guard let relative = files.first(where: { URL(fileURLWithPath: $0).lastPathComponent == name }) else {
            throw TestFailure("archive is missing \(name)")
        }
        return expanded.appendingPathComponent(relative)
    }

    private static func runDitto(_ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        try expect(task.terminationStatus == 0, "ditto failed with \(task.terminationStatus)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
