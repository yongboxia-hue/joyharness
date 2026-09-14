import Foundation

struct ControllerStatus: Equatable, Sendable {
    var connected = false
    /// Asleep is not the same as missing: the controller powered down on its
    /// own after sitting idle and comes back on the next button press, so the
    /// UI should say that instead of reporting it as gone.
    var asleep = false
    var batteryLevel: Int?
    var charging = false

    var statusText: String {
        if connected { return "已连接" }
        return asleep ? "已休眠" : "未连接"
    }
}

struct RuntimeInputEvent: Identifiable, Equatable, Sendable {
    let sequence: Int
    let button: String
    let phase: String
    let timestamp: TimeInterval

    var id: Int { sequence }

    static func parse(_ value: Any?) -> [RuntimeInputEvent] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.compactMap { item in
            guard
                let sequence = item["sequence"] as? Int,
                let button = item["button"] as? String,
                let phase = item["phase"] as? String,
                let timestamp = item["timestamp"] as? Double
            else { return nil }
            return RuntimeInputEvent(
                sequence: sequence,
                button: button,
                phase: phase,
                timestamp: timestamp
            )
        }
    }
}

enum ControllerStatusParser {
    static func parse(_ value: Any?) -> ControllerStatus {
        guard let values = value as? [Any], !values.isEmpty else {
            return ControllerStatus()
        }

        let status = values[0] as? String ?? "unknown"
        let level = values.count > 1 ? values[1] as? Int : nil
        return ControllerStatus(
            connected: ["connected", "charging", "discharging"].contains(status),
            asleep: status == "asleep",
            batteryLevel: (level ?? -1) >= 0 ? min(level ?? 0, 4) : nil,
            charging: status == "charging"
        )
    }
}


/// One step of the onboarding button test, derived from the installed mappings.
struct OnboardingCheck: Identifiable, Equatable {
    /// The progress key this check records when it happens.
    let id: String
    /// The mapping's button name, as the runtime reports it in input events.
    let button: String
    let isLongPress: Bool
    /// What is printed on the controller ("ZR", "−", "→"), from the card.
    let key: String
    /// The shortcut that button actually sends, rendered from the config.
    let shortcut: String

    var gesture: String { isLongPress ? "按住不放" : "按一下" }
}
