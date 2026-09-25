import Foundation

enum RuntimeClientError: LocalizedError {
    case busy
    case timeout
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        // These reach the user verbatim, so they name the action and what to
        // do about it rather than the Python process behind it -- the same
        // rule the 关于 page follows ("重启服务", never "后台服务").
        case .busy:
            return String(localized: "上一步还没做完，稍等一下。")
        case .timeout:
            return String(localized: "JoyHarness 没有响应。在「关于」里重启一次再试。")
        case .rejected(let message):
            return message
        case .invalidResponse:
            return String(localized: "出了点问题。在「关于」里重启一次再试。")
        }
    }
}

actor RuntimeClient {
    private struct Command: Encodable {
        let id: String
        let type: String
        let payload: [String: CommandValue]?
    }

    enum CommandValue: Encodable {
        case bool(Bool)
        case strings([String])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .strings(let value): try container.encode(value)
            }
        }
    }

    private struct Response: Decodable {
        let id: String
        let type: String
        let ok: Bool
        let result: [String: JSONValue]
        let error: String?
    }

    private enum JSONValue: Decodable {
        case bool(Bool)
        case string(String)
        case number(Double)
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
        }
    }

    private let ipcURL: URL
    private var requestInFlight = false

    init(ipcURL: URL) {
        self.ipcURL = ipcURL
    }

    /// Suspend key output without recording it as the user's choice.
    ///
    /// The walkthrough's key steps let through only the key being taught, so
    /// it really works while a stray press elsewhere does nothing. That hold
    /// belongs to the sheet, not to the user -- so it deliberately does not
    /// go through set_paused, which persists. Releasing it puts back whatever
    /// the user's own pause says.
    @discardableResult
    func holdOutput(_ held: Bool, allowing buttons: [String]? = nil) async throws -> Bool {
        var payload: [String: CommandValue] = ["held": .bool(held)]
        if let buttons { payload["allow"] = .strings(buttons) }
        let response = try await send(type: "hold_output", payload: payload)
        guard case .bool(let confirmed)? = response.result["held"] else {
            throw RuntimeClientError.invalidResponse
        }
        return confirmed
    }

    /// A pulse on every connected controller: the "this one" signal when a
    /// controller connects during the walkthrough.
    func buzz(long: Bool) async throws {
        _ = try await send(type: "buzz", payload: ["long": .bool(long)])
    }

    func setPaused(_ paused: Bool) async throws -> Bool {
        let response = try await send(type: "set_paused", payload: ["paused": .bool(paused)])
        guard case .bool(let confirmed)? = response.result["paused"] else {
            throw RuntimeClientError.invalidResponse
        }
        return confirmed
    }

    func reloadConfig() async throws {
        _ = try await send(type: "reload_config", payload: nil)
    }

    private func send(type: String, payload: [String: CommandValue]?) async throws -> Response {
        guard !requestInFlight else { throw RuntimeClientError.busy }
        requestInFlight = true
        defer { requestInFlight = false }

        let manager = FileManager.default
        try manager.createDirectory(at: ipcURL, withIntermediateDirectories: true)
        let commandURL = ipcURL.appendingPathComponent("command.json")
        let resultURL = ipcURL.appendingPathComponent("command-result.json")
        let requestID = UUID().uuidString.lowercased()
        let command = Command(id: requestID, type: type, payload: payload)
        let data = try JSONEncoder().encode(command)
        try data.write(to: commandURL, options: .atomic)

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if let resultData = try? Data(contentsOf: resultURL),
               let response = try? JSONDecoder().decode(Response.self, from: resultData),
               response.id == requestID {
                guard response.type == type else { throw RuntimeClientError.invalidResponse }
                guard response.ok else {
                    throw RuntimeClientError.rejected(response.error ?? String(localized: "JoyHarness 没有接受这次操作。"))
                }
                return response
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RuntimeClientError.timeout
    }
}
