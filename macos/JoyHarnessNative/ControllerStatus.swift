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


/// What a walkthrough key step teaches. The order here is the order taught:
/// put the cursor in the box, say something, fix it, send it.
enum OnboardingLesson: String, CaseIterable, Sendable {
    case focus, voice, delete, send
}

/// One walkthrough key step, derived from the installed mappings.
struct OnboardingCheck: Identifiable, Equatable {
    let lesson: OnboardingLesson
    /// The mapping's button name, as the runtime reports it in input events.
    let button: String
    /// What is printed on the controller ("ZR", "−", "→"), from the card.
    let key: String
    /// Where that key sits on the controller drawing.
    let hotspotKey: String
    /// The shortcut a tap sends, rendered from the config.
    let shortcut: String
    /// The button also has a long press, so only a tap counts.
    let tapOnly: Bool

    /// The progress key this check records when it happens.
    var id: String { lesson.rawValue }
}

struct OnboardingPressFlash: Equatable {
    let button: String
    let count: Int
}
