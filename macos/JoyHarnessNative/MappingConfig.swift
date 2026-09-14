import Foundation

enum ControllerSide: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { self == .left ? "左手柄" : "右手柄" }
    var imageName: String { self == .left ? "JoyConLeft" : "JoyConRight" }
    var profileName: String { self == .left ? "single_left" : "single_right" }
}

/// One line on a button's card.
///
/// `gesture` is nil when the button does a single thing: it is simply that
/// key, and labelling the only line "单击" would imply a distinction that
/// does not exist there.
struct MappingRow: Identifiable, Equatable {
    let id: String
    let gesture: String?
    let value: String
}

struct MappingCardModel: Identifiable, Equatable {
    let id: String
    let key: String
    let hotspotKey: String
    let rows: [MappingRow]
}

struct MappingConfiguration {
    var cardsBySide: [ControllerSide: [MappingCardModel]] = [:]

    static let empty = MappingConfiguration()
}

struct ControllerHotspot: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
}

enum ControllerHotspotReader {
    private struct Payload: Decodable {
        let points: [String: [String: ControllerHotspot]]
    }

    static func load() -> [ControllerSide: [String: ControllerHotspot]] {
        guard let url = Bundle.main.url(forResource: "controller-hotspots", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        return [.left: payload.points["left"] ?? [:], .right: payload.points["right"] ?? [:]]
    }
}

enum MappingConfigReader {
    static func load(from url: URL) throws -> MappingConfiguration {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let profiles = root["profiles"] as? [String: Any] ?? [:]
        var result: [ControllerSide: [MappingCardModel]] = [:]
        for side in ControllerSide.allCases {
            let profile = profiles[side.profileName] as? [String: Any] ?? [:]
            let mappings = profile["mappings"] as? [String: Any] ?? [:]
            let buttons = mappings["buttons"] as? [String: Any] ?? [:]
            result[side] = buttonSpecs(for: side).map { button, display, hotspot in
                let mapping = buttons[button] as? [String: Any]
                return MappingCardModel(
                    id: button,
                    key: display,
                    hotspotKey: hotspot,
                    rows: rows(for: mapping)
                )
            }
        }
        return MappingConfiguration(cardsBySide: result)
    }

    // No `isBuiltIn` on the card: nothing drew it, and deciding "is this a
    // built-in" here as well as in the editor is how two answers to one
    // question get out of step. ActionCatalog.twoLevelActions is the answer.

    /// The lines to show for one button.
    ///
    /// Only an action whose two levels are genuinely part of it (see
    /// ActionCatalog.twoLevelActions) draws two lines. window_switch used to
    /// draw them too, promising a 长按 the shipped runtime has no way to honour.
    ///
    /// A passthrough button gets one unlabelled line -- it is that key, and
    /// holding it repeats exactly like holding the key does. Anything split
    /// into gestures gets one labelled line per gesture that is actually
    /// configured; gestures that were never set are simply absent rather
    /// than listed as "未设置", which used to make a button's most important
    /// behaviour (holding ⌫ to keep deleting) look unconfigured.
    private static func rows(for mapping: [String: Any]?) -> [MappingRow] {
        guard let mapping else { return [MappingRow(id: "only", gesture: nil, value: "未设置")] }

        switch mapping["action"] as? String ?? "disabled" {
        case "app_switch_mode":
            return [MappingRow(id: "single", gesture: "单击", value: "⌘Tab"),
                    MappingRow(id: "long", gesture: "长按", value: "切换应用")]
        case "short_long":
            return slots(mapping, [("single", "单击", "short"), ("long", "长按", "long")])
        case "double_tap":
            return slots(mapping, [("single", "单击", "single"), ("double", "双击", "double")])
        case "multi_trigger":
            return slots(mapping, [("single", "单击", "tap"), ("double", "双击", "double"), ("long", "长按", "hold")])
        case "disabled":
            return [MappingRow(id: "only", gesture: nil, value: "未设置")]
        default:
            return [MappingRow(id: "only", gesture: nil, value: formatAction(mapping))]
        }
    }

    private static func slots(
        _ mapping: [String: Any],
        _ spec: [(id: String, title: String, key: String)]
    ) -> [MappingRow] {
        let rows = spec.compactMap { entry -> MappingRow? in
            guard let slot = mapping[entry.key] as? [String: Any] else { return nil }
            let label = formatAction(slot)
            guard label != "未设置" else { return nil }
            return MappingRow(id: entry.id, gesture: entry.title, value: label)
        }
        return rows.isEmpty ? [MappingRow(id: "only", gesture: nil, value: "未设置")] : rows
    }

    /// Human-readable label for one mapping or one gesture slot.
    static func formatAction(_ mapping: [String: Any]?) -> String {
        guard let mapping else { return "未设置" }

        // Both a passthrough button and a gesture slot are just keys; the
        // slot omits the action name because it has no behaviour of its own.
        if let keys = mapping["keys"] as? [String] {
            let action = mapping["action"] as? String
            if action == nil || action == "passthrough" {
                return keys.map(keyLabel).joined()
            }
        }

        return ActionCatalog.name(of: mapping["action"] as? String ?? "disabled")
    }

    private static func keyLabel(_ key: String?) -> String {
        guard let key else { return "未设置" }
        return KeyboardKeyCatalog.label(for: key)
    }

    private static func buttonSpecs(for side: ControllerSide) -> [(String, String, String)] {
        if side == .right {
            return [("R", "R", "R"), ("Plus", "+", "+"), ("Y", "Y", "Y"), ("SL", "SL", "SL"), ("Home", "Home", "Home"), ("ZR", "ZR", "ZR"), ("X", "X", "X"), ("A", "A", "A"), ("SR", "SR", "SR"), ("B", "B", "B"), ("RStick", "摇杆", "摇杆")]
        }
        // Positionally aligned with the right controller's diamond layout
        // (Up=X/top, Right=A/right, Down=B/bottom, Left=Y/left) to match
        // side_button_reader._LEFT_BUTTON_BITS on the runtime side -- these
        // two tables previously disagreed on Up/Down (X and B were swapped
        // here), so a physical Up press correctly fired the "X" mapping at
        // runtime while the UI drew "X" at the Down hotspot.
        return [("L", "L", "L"), ("ZL", "ZL", "ZL"), ("Minus", "−", "−"), ("LStick", "摇杆", "摇杆"), ("X", "↑", "↑"), ("Y", "←", "←"), ("SR", "SR", "SR"), ("A", "→", "→"), ("B", "↓", "↓"), ("SL", "SL", "SL"), ("Capture", "截图", "截图")]
    }
}
