import AppKit
import CoreGraphics
import Foundation

enum KeyboardKeyCatalog {
    private static let aliases: [String: String] = [
        "command": "cmd", "cmd_l": "cmd", "windows": "cmd", "win": "cmd", "super": "cmd",
        "control": "ctrl", "ctrl_l": "ctrl",
        "option": "alt", "alt_l": "alt",
        "return": "enter", "esc": "escape", "function": "fn"
    ]

    private static let displayLabels: [String: String] = [
        "cmd": "⌘", "cmd_r": "⌘",
        "ctrl": "⌃", "ctrl_r": "⌃",
        "alt": "⌥", "alt_r": "⌥",
        "shift": "⇧", "shift_l": "⇧", "shift_r": "⇧",
        "enter": "↩", "escape": "Esc", "backspace": "⌫", "delete": "⌦",
        "space": "Space", "tab": "Tab", "fn": "fn", "caps_lock": "Caps Lock",
        "page_up": "Page Up", "page_down": "Page Down", "home": "Home", "end": "End",
        "up": "↑", "down": "↓", "left": "←", "right": "→"
    ]

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
        "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "backspace": 51, "escape": 53, "cmd_r": 54, "cmd": 55, "shift": 56,
        "shift_l": 56, "caps_lock": 57, "alt": 58, "ctrl": 59, "shift_r": 60,
        "alt_r": 61, "ctrl_r": 62, "fn": 63, "f17": 64, "f18": 79, "f19": 80,
        "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100,
        "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107,
        "f10": 109, "f12": 111, "f15": 113, "home": 115, "page_up": 116,
        "delete": 117, "f4": 118, "end": 119, "f2": 120, "page_down": 121,
        "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126,
        "print_screen": 105, "insert": 107, "menu": 113, "pause": 64,
        "scroll_lock": 79, "num_lock": 106
    ]

    private static let recordedKeyNames: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y",
        17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "enter", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 48: "tab", 49: "space", 50: "`",
        51: "backspace", 53: "escape", 57: "caps_lock", 64: "f17", 79: "f18",
        80: "f19", 90: "f20", 96: "f5", 97: "f6", 98: "f7", 99: "f3",
        100: "f8", 101: "f9", 103: "f11", 105: "f13", 106: "f16",
        107: "f14", 109: "f10", 111: "f12", 113: "f15", 115: "home",
        116: "page_up", 117: "delete", 118: "f4", 119: "end", 120: "f2",
        121: "page_down", 122: "f1", 123: "left", 124: "right", 125: "down", 126: "up"
    ]

    static func normalize(_ rawKey: String) -> String {
        let key = rawKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return aliases[key] ?? key
    }

    static func keyCode(for rawKey: String) -> CGKeyCode? {
        keyCodes[normalize(rawKey)]
    }

    static func label(for rawKey: String) -> String {
        let key = normalize(rawKey)
        return displayLabels[key] ?? key.uppercased()
    }

    static func display(keys: [String]) -> String {
        keys.map(label).joined()
    }

    /// Build a shortcut from a key-down event -- a regular key plus whatever
    /// modifiers are held.
    ///
    /// `.function` is deliberately NOT read here. macOS sets that flag on
    /// every key it considers a "function key" -- the arrows, F1-F20,
    /// Home/End/Page Up/Page Down -- whether or not the fn key is actually
    /// down, so trusting it would record ↑ as "fn↑". The fn key on its own
    /// never produces a key-down event at all (it is a modifier, so it only
    /// ever shows up in flags-changed), which is why it is recorded through
    /// `modifiers(from:)` below instead.
    static func shortcut(from event: NSEvent) -> ShortcutDefinition? {
        guard let key = recordedKeyNames[event.keyCode] else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var keys: [String] = []
        if flags.contains(.command) { keys.append("cmd") }
        if flags.contains(.control) { keys.append("ctrl") }
        if flags.contains(.option) { keys.append("alt") }
        if flags.contains(.shift) { keys.append("shift") }
        keys.append(key)
        return ShortcutDefinition(keys: keys)
    }

    /// The modifiers held during a flags-changed event, in display order.
    ///
    /// Unlike the key-down path this *does* trust `.function`: only the fn
    /// key itself generates a flags-changed event carrying that flag, so
    /// here it unambiguously means fn is down. This is the only way fn can
    /// be recorded -- no key-down event is ever emitted for it.
    static func modifiers(from event: NSEvent) -> [String] {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var keys: [String] = []
        if flags.contains(.command) { keys.append("cmd") }
        if flags.contains(.control) { keys.append("ctrl") }
        if flags.contains(.option) { keys.append("alt") }
        if flags.contains(.shift) { keys.append("shift") }
        if flags.contains(.function) { keys.append("fn") }
        return keys
    }
}

struct ShortcutDefinition: Equatable {
    let keys: [String]

    init?(keys: [String]) {
        var normalized: [String] = []
        for rawKey in keys {
            let key = KeyboardKeyCatalog.normalize(rawKey)
            guard KeyboardKeyCatalog.keyCode(for: key) != nil else { return nil }
            if !normalized.contains(key) { normalized.append(key) }
        }
        guard !normalized.isEmpty else { return nil }
        self.keys = normalized
    }

    var displayLabel: String { KeyboardKeyCatalog.display(keys: keys) }

    /// A whole button: it *is* this key, held and repeating like the keyboard.
    var passthroughMapping: [String: Any] {
        ["action": "passthrough", "keys": keys]
    }

    /// One slot of a gesture split -- sent once, so it names no action.
    var slotMapping: [String: Any] {
        ["keys": keys]
    }

    static func parse(_ input: String) throws -> ShortcutDefinition {
        var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw ShortcutParseError.empty }

        let replacements = [
            ("command", " cmd "), ("control", " ctrl "), ("option", " alt "),
            ("return", " enter "), ("escape", " escape "), ("backspace", " backspace "),
            ("page up", " page_up "), ("page down", " page_down "),
            ("⌘", " cmd "), ("⌃", " ctrl "), ("⌥", " alt "), ("⇧", " shift "),
            ("↩", " enter "), ("⌫", " backspace "), ("⌦", " delete "),
            ("↑", " up "), ("↓", " down "), ("←", " left "), ("→", " right ")
        ]
        for (source, target) in replacements {
            normalized = normalized.replacingOccurrences(of: source, with: target)
        }

        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "+,"))
        let tokens = normalized.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ShortcutParseError.empty }

        var modifiers: [String] = []
        var regularKeys: [String] = []
        for token in tokens {
            let key = KeyboardKeyCatalog.normalize(token)
            guard KeyboardKeyCatalog.keyCode(for: key) != nil else {
                throw ShortcutParseError.unsupported(token)
            }
            if ["cmd", "cmd_r", "ctrl", "ctrl_r", "alt", "alt_r", "shift", "shift_r", "fn"].contains(key) {
                if !modifiers.contains(key) { modifiers.append(key) }
            } else if !regularKeys.contains(key) {
                regularKeys.append(key)
            }
        }
        guard regularKeys.count <= 1 else { throw ShortcutParseError.multipleRegularKeys }
        guard let shortcut = ShortcutDefinition(keys: modifiers + regularKeys) else {
            throw ShortcutParseError.empty
        }
        return shortcut
    }
}

enum ShortcutParseError: LocalizedError {
    case empty
    case unsupported(String)
    case multipleRegularKeys

    var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "请输入一个快捷键")
        case .unsupported(let key): return String(localized: "不支持按键“\(key)”")
        case .multipleRegularKeys: return String(localized: "一个快捷键只能包含一个普通按键")
        }
    }
}
