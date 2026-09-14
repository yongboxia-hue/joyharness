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
            return "上一个操作还没完成，请稍后再试。"
        case .timeout:
            return "JoyHarness 暂时没有响应，可以在「关于 → 系统」里重启一次再试。"
        case .rejected(let message):
            return message
        case .invalidResponse:
            return "收到了无法识别的结果，可以在「关于 → 系统」里重启一次再试。"
        }
    }
}

actor RuntimeClient {
    private struct Command: Encodable {
        let id: String
        let type: String
        let payload: [String: Bool]?
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
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
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
    /// The onboarding button test needs the presses it is teaching to stay
    /// silent, but that hold belongs to the sheet, not to the user -- so it
    /// deliberately does not go through set_paused, which persists.
    @discardableResult
    func holdOutput(_ held: Bool) async throws -> Bool {
        let response = try await send(type: "hold_output", payload: ["held": held])
        guard case .bool(let confirmed)? = response.result["held"] else {
            throw RuntimeClientError.invalidResponse
        }
        return confirmed
    }

    func setPaused(_ paused: Bool) async throws -> Bool {
        let response = try await send(type: "set_paused", payload: ["paused": paused])
        guard case .bool(let confirmed)? = response.result["paused"] else {
            throw RuntimeClientError.invalidResponse
        }
        return confirmed
    }

    func reloadConfig() async throws {
        _ = try await send(type: "reload_config", payload: nil)
    }

    private func send(type: String, payload: [String: Bool]?) async throws -> Response {
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
                    throw RuntimeClientError.rejected(response.error ?? "后台服务拒绝了这次操作。")
                }
                return response
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RuntimeClientError.timeout
    }
}
