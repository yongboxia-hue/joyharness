import Foundation

final class RecordingEmitter: KeyboardEventEmitting {
    private let lock = NSLock()
    private(set) var events: [String] = []

    func setKey(_ key: String, down: Bool) throws {
        if key == "invalid" { throw InputGatewayError.unsupportedKey(key) }
        lock.lock(); events.append("\(down ? "down" : "up"):\(key)"); lock.unlock()
    }

    func typeText(_ text: String) throws {
        lock.lock(); events.append("text:\(text)"); lock.unlock()
    }
}

@main
enum NativeInputGatewayTests {
    static func main() throws {
        try expect(try ShortcutDefinition.parse("⌘V").keys == ["cmd", "v"], "symbol shortcut parsing failed")
        try expect(try ShortcutDefinition.parse("Command+V").displayLabel == "⌘V", "named shortcut parsing failed")
        // A whole button declares passthrough; one slot of a gesture split
        // carries only keys, because it has no behaviour of its own.
        try expect(try ShortcutDefinition.parse("Option+A").passthroughMapping["keys"] as? [String] == ["alt", "a"], "passthrough keys failed")
        try expect(try ShortcutDefinition.parse("Option+A").passthroughMapping["action"] as? String == "passthrough", "passthrough action failed")
        try expect(try ShortcutDefinition.parse("fn").slotMapping["keys"] as? [String] == ["fn"], "slot keys failed")
        try expect(try ShortcutDefinition.parse("fn").slotMapping["action"] == nil, "a gesture slot names no action")

        guard CommandLine.arguments.count == 2 else { throw TestFailure("missing repository root") }
        let repository = CommandLine.arguments[1]
        let manager = FileManager.default
        let identifier = UUID().uuidString.prefix(8)
        let socketURL = URL(fileURLWithPath: "/tmp/jh-\(identifier).sock")
        defer { try? manager.removeItem(at: socketURL) }
        let emitter = RecordingEmitter()
        let gateway = InputGateway(socketURL: socketURL, emitter: emitter)
        try gateway.start()
        defer { gateway.stop() }

        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-c", pythonProgram]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = repository
        environment["JOYHARNESS_TEST_SOCKET"] = socketURL.path
        python.environment = environment
        let errorPipe = Pipe()
        python.standardError = errorPipe
        try python.run()
        python.waitUntilExit()
        if python.terminationStatus != 0 {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TestFailure("Python gateway client failed: \(error)")
        }

        let expected = [
            "down:cmd",
            "up:cmd", "down:cmd", "up:cmd", "down:cmd",
            "up:cmd", "down:cmd", "down:v", "up:v", "up:cmd", "down:cmd",
            "text:hello", "up:cmd"
        ]
        if emitter.events != expected {
            throw TestFailure("unexpected event sequence:\n\(emitter.events)")
        }
        print("Native input gateway Python/Swift round-trip passed.")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(message) }
    }

    private static let pythonProgram = #"""
import os
from src.native_input_client import NativeInputClient, NativeInputError

client = NativeInputClient(os.environ["JOYHARNESS_TEST_SOCKET"])
client.request("ping")
client.request("press", key="cmd")
client.request("tap", key="cmd", duration_ms=1)
client.request("combination", keys=["cmd", "v"], hold_ms=1)
client.request("type_text", text="hello")
client.request("release", key="cmd")
try:
    client.request("tap", key="invalid", duration_ms=1)
except NativeInputError as error:
    assert "Unsupported key" in str(error)
else:
    raise AssertionError("invalid key was accepted")
client.request("release_all")
"""#
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
