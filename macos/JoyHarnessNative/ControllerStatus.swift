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
        if connected { return String(localized: "已连接") }
        return asleep ? String(localized: "已休眠") : String(localized: "未连接")
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


/// What a walkthrough key step teaches.
enum OnboardingLesson: String, CaseIterable, Sendable {
    case focus, voice, send, paste, trim, newline
}

/// How the key has to be pressed for the step to count.
enum OnboardingGesture: Sendable {
    /// Under the long-press threshold -- A held is a new line, not a send.
    case tap
    /// Past the threshold: the long press, or the repeat of a held key.
    case hold
    /// Either. Voice tools differ: some want fn held, some toggle on a tap.
    case either
}

/// One walkthrough key step, derived from the installed mappings.
///
/// Steps repeat lessons -- the practice speaks and sends twice -- so a step
/// has its own id rather than borrowing its lesson's name.
struct OnboardingCheck: Identifiable, Equatable {
    let id: String
    let lesson: OnboardingLesson
    let gesture: OnboardingGesture
    /// 1 for the first exchange (focus, speak, send), 2 for the editing one.
    let round: Int
    /// The mapping's button name, as the runtime reports it in input events.
    let button: String
    /// What is printed on the controller ("ZR", "−", "→"), from the card.
    let key: String
    /// Where that key sits on the controller drawing.
    let hotspotKey: String
    /// The shortcut this gesture sends, rendered from the config.
    let shortcut: String
    /// The button does something else when held, so a tap must stay short.
    let splitsOnHold: Bool
}

struct OnboardingPressFlash: Equatable {
    let button: String
    let count: Int
    /// Released after the long-press threshold: a hold, not a tap.
    var held = false
}
