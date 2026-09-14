import CoreGraphics
import Darwin
import Foundation

enum InputGatewayError: LocalizedError {
    case invalidRequest(String)
    case unsupportedKey(String)
    case eventCreationFailed
    case socketFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .unsupportedKey(let key): return "Unsupported key: \(key)"
        case .eventCreationFailed: return "Unable to create a keyboard event"
        case .socketFailure(let message): return message
        }
    }
}

protocol KeyboardEventEmitting: AnyObject {
    func setKey(_ key: String, down: Bool) throws
    func typeText(_ text: String) throws
}

final class CoreGraphicsKeyboardEmitter: KeyboardEventEmitting {
    func setKey(_ key: String, down: Bool) throws {
        guard let keyCode = Self.keyCode(for: key) else { throw InputGatewayError.unsupportedKey(key) }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
            throw InputGatewayError.eventCreationFailed
        }
        // REVERTED: an earlier pass here set event.flags = [] on every
        // posted event, on the theory that a modifier held via a separate
        // "hold" mapping (e.g. R -> Option) could leak into an unrelated
        // tap. That was wrong -- "combination" (e.g. Cmd+V) depends on
        // exactly this ambient-flags propagation: pressing "cmd" down does
        // not, by itself, make the OS report Cmd as active on the "v" event
        // that follows unless the ambient CGEventSourceStateID.combinedSessionState
        // carries it through, which explicitly zeroing flags here defeated.
        // Confirmed via real hardware: with flags forced to [], Plus (short
        // press = Cmd+V) posted a bare "v" with no modifier. If the original
        // stray-modifier leak into a plain tap turns out to be real, it
        // needs a fix that only touches tap/press/release, not combination.
        event.post(tap: .cghidEventTap)
    }

    func typeText(_ text: String) throws {
        var characters = Array(text.utf16)
        guard !characters.isEmpty else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw InputGatewayError.eventCreationFailed
        }
        down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
        up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func keyCode(for rawKey: String) -> CGKeyCode? {
        KeyboardKeyCatalog.keyCode(for: rawKey)
    }
}

final class InputGateway {
    private let socketURL: URL
    private let emitter: KeyboardEventEmitting
    private let queue = DispatchQueue(label: "com.yongboxia.joyharness.input-gateway", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.yongboxia.joyharness.input-clients", qos: .userInitiated)
    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var heldKeys = Set<String>()

    init(socketURL: URL, emitter: KeyboardEventEmitting = CoreGraphicsKeyboardEmitter()) {
        self.socketURL = socketURL
        self.emitter = emitter
    }

    func start() throws {
        guard serverFD < 0 else { return }
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw InputGatewayError.socketFailure("Input socket path is too long")
        }
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: socketURL)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw InputGatewayError.socketFailure("Unable to create input socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    _ = strlcpy($0, source, pathCapacity)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw InputGatewayError.socketFailure("Unable to bind input socket")
        }
        chmod(path, S_IRUSR | S_IWUSR)
        serverFD = descriptor
        queue.async { [weak self] in self?.acceptLoop(descriptor: descriptor) }
    }

    func stop() {
        stateLock.lock()
        let descriptor = serverFD
        serverFD = -1
        stateLock.unlock()
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
        clientQueue.sync {
            stateLock.lock()
            let keys = heldKeys
            heldKeys.removeAll()
            stateLock.unlock()
            for key in keys { try? emitter.setKey(key, down: false) }
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop(descriptor: Int32) {
        while serverFD == descriptor {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { break }
            clientQueue.async { [weak self] in self?.handleClient(client) }
        }
    }

    private func handleClient(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(buffer, count: count)
            guard let newline = data.firstIndex(of: 0x0A) else {
                if data.count > 65_536 { return }
                continue
            }
            let requestData = data[..<newline]
            let response = process(Data(requestData))
            guard let encoded = try? JSONSerialization.data(withJSONObject: response), !encoded.isEmpty else { return }
            var payload = encoded + Data("\n".utf8)
            payload.withUnsafeMutableBytes { bytes in
                if let base = bytes.baseAddress { _ = Darwin.write(descriptor, base, bytes.count) }
            }
            return
        }
    }

    private func process(_ data: Data) -> [String: Any] {
        var identifier = ""
        var operation = ""
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InputGatewayError.invalidRequest("Request must be a JSON object")
            }
            identifier = request["id"] as? String ?? ""
            operation = request["operation"] as? String ?? ""
            guard !identifier.isEmpty, !operation.isEmpty else {
                throw InputGatewayError.invalidRequest("Request requires id and operation")
            }
            let detail = try execute(operation: operation, request: request)
            var response: [String: Any] = ["id": identifier, "operation": operation, "ok": true]
            if let detail { response["detail"] = detail }
            return response
        } catch {
            return ["id": identifier, "operation": operation, "ok": false, "error": error.localizedDescription]
        }
    }

    @discardableResult
    private func execute(operation: String, request: [String: Any]) throws -> String? {
        switch operation {
        case "ping": return nil
        case "focus_input":
            return try InputFocus.focusFrontmostInput()
        case "press": try press(requiredKey(request))
        case "release": try release(requiredKey(request))
        case "tap":
            let key = try requiredKey(request)
            stateLock.lock(); let wasHeld = heldKeys.contains(key); stateLock.unlock()
            do {
                if wasHeld { try emitter.setKey(key, down: false) }
                try emitter.setKey(key, down: true)
                usleep(useconds_t(max(1, request["duration_ms"] as? Int ?? 20) * 1000))
                try emitter.setKey(key, down: false)
                if wasHeld { try emitter.setKey(key, down: true) }
            } catch {
                try? emitter.setKey(key, down: false)
                if wasHeld { try? emitter.setKey(key, down: true) }
                throw error
            }
        case "combination":
            guard let keys = request["keys"] as? [String], !keys.isEmpty else {
                throw InputGatewayError.invalidRequest("combination requires keys")
            }
            stateLock.lock(); let heldInCombination = keys.filter { heldKeys.contains($0.lowercased()) }; stateLock.unlock()
            var pressedKeys: [String] = []
            do {
                for key in heldInCombination { try emitter.setKey(key, down: false) }
                for key in keys {
                    try emitter.setKey(key, down: true)
                    pressedKeys.append(key)
                    usleep(10_000)
                }
                usleep(useconds_t(max(1, request["hold_ms"] as? Int ?? 50) * 1000))
                for key in pressedKeys.reversed() { try emitter.setKey(key, down: false) }
                pressedKeys.removeAll()
                for key in heldInCombination { try emitter.setKey(key, down: true) }
            } catch {
                for key in pressedKeys.reversed() { try? emitter.setKey(key, down: false) }
                for key in heldInCombination { try? emitter.setKey(key, down: true) }
                throw error
            }
        case "type_text":
            guard let text = request["text"] as? String else { throw InputGatewayError.invalidRequest("type_text requires text") }
            try emitter.typeText(text)
        case "release_all":
            stateLock.lock(); let keys = heldKeys; heldKeys.removeAll(); stateLock.unlock()
            for key in keys { try emitter.setKey(key, down: false) }
        default: throw InputGatewayError.invalidRequest("Unsupported operation: \(operation)")
        }
        return nil
    }

    private func requiredKey(_ request: [String: Any]) throws -> String {
        guard let key = request["key"] as? String, !key.isEmpty else { throw InputGatewayError.invalidRequest("operation requires key") }
        return key.lowercased()
    }

    private func press(_ key: String) throws {
        stateLock.lock(); let inserted = heldKeys.insert(key).inserted; stateLock.unlock()
        if inserted {
            do { try emitter.setKey(key, down: true) }
            catch { stateLock.lock(); heldKeys.remove(key); stateLock.unlock(); throw error }
        }
    }

    private func release(_ key: String) throws {
        stateLock.lock(); let existed = heldKeys.remove(key) != nil; stateLock.unlock()
        if existed {
            do { try emitter.setKey(key, down: false) }
            catch { stateLock.lock(); heldKeys.insert(key); stateLock.unlock(); throw error }
        }
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var value = lhs
    value.append(rhs)
    return value
}
