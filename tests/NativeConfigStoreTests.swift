import Foundation

@main
enum NativeConfigStoreTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("joyharness-config-store-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let ipcDirectory = root.appendingPathComponent("ipc", isDirectory: true)
        try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: ipcDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let configURL = configDirectory.appendingPathComponent("user.json")
        let initial = config(marker: "initial")
        try encoded(initial).write(to: configURL, options: .atomic)

        let client = RuntimeClient(ipcURL: ipcDirectory)
        let store = ConfigStore(configURL: configURL, runtimeClient: client)

        let successResponder = Task { try await respond(ipcURL: ipcDirectory, outcomes: [true]) }
        try await store.save(config(marker: "accepted"))
        try await successResponder.value
        let acceptedMarker = try marker(at: configURL)
        try expect(acceptedMarker == "accepted", "accepted save was not persisted")

        let rollbackResponder = Task { try await respond(ipcURL: ipcDirectory, outcomes: [false, true]) }
        do {
            try await store.save(config(marker: "rejected"))
            throw TestFailure("rejected save unexpectedly succeeded")
        } catch is RuntimeClientError {
            // Expected: the original runtime rejection is rethrown after rollback succeeds.
        }
        try await rollbackResponder.value
        let rolledBackMarker = try marker(at: configURL)
        try expect(rolledBackMarker == "accepted", "rejected save did not roll back")

        let backups = try manager.contentsOfDirectory(at: configDirectory.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        try expect(backups.count == 2, "expected two timestamped backups, found \(backups.count)")
        print("Native ConfigStore success and rollback tests passed.")
    }

    private static func config(marker: String) -> [String: Any] {
        [
            "marker": marker,
            "profiles": [
                "single_left": ["mappings": ["buttons": ["A": ["action": "tap", "key": "enter"]]]],
                "single_right": ["mappings": ["buttons": ["A": ["action": "tap", "key": "enter"]]]]
            ]
        ]
    }

    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func marker(at url: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["marker"] as? String
    }

    private static func respond(ipcURL: URL, outcomes: [Bool]) async throws {
        let commandURL = ipcURL.appendingPathComponent("command.json")
        let resultURL = ipcURL.appendingPathComponent("command-result.json")
        for outcome in outcomes {
            let deadline = Date().addingTimeInterval(3)
            var command: [String: Any]?
            while Date() < deadline && command == nil {
                if let data = try? Data(contentsOf: commandURL) {
                    command = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                if command == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            }
            guard let command, let identifier = command["id"] as? String, let type = command["type"] as? String else {
                throw TestFailure("fake runtime did not receive a command")
            }
            try? FileManager.default.removeItem(at: commandURL)
            let response: [String: Any] = [
                "id": identifier,
                "type": type,
                "ok": outcome,
                "result": [:],
                "error": outcome ? NSNull() : "test rejection"
            ]
            try encoded(response).write(to: resultURL, options: .atomic)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
