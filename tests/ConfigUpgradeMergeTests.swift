import Foundation

// What an upgrade is allowed to do to a config someone has edited.
//
// Until 0.2.0 it replaced the whole file, so a remapped button went to a
// timestamped backup nobody had a reason to look for. These cases pin the rule
// that replaced it: a value the user still shares with the defaults they were
// given moves to the new default; a value they changed stays.

@main
enum ConfigUpgradeMergeTests {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if ok {
            print("  ok   \(label)")
        } else {
            let extra = detail()
            print("  FAIL \(label)" + (extra.isEmpty ? "" : "\n       \(extra)"))
            failures.append(label)
        }
    }

    static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func describe(_ value: Any?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "nil" }
        return text
    }

    static func buttons(_ merged: [String: Any]) -> [String: Any] {
        let profiles = merged["profiles"] as! [String: Any]
        let profile = profiles["single_right"] as! [String: Any]
        let mappings = profile["mappings"] as! [String: Any]
        return mappings["buttons"] as! [String: Any]
    }

    static func withButton(_ config: [String: Any], _ name: String, _ value: Any) -> [String: Any] {
        var config = config
        var profiles = config["profiles"] as! [String: Any]
        var profile = profiles["single_right"] as! [String: Any]
        var mappings = profile["mappings"] as! [String: Any]
        var mapped = mappings["buttons"] as! [String: Any]
        mapped[name] = value
        mappings["buttons"] = mapped
        profile["mappings"] = mappings
        profiles["single_right"] = profile
        config["profiles"] = profiles
        return config
    }

    static func main() {
        let baseline = json("""
        {
          "config_version": 8,
          "idle_sleep_minutes": 10,
          "profiles": { "single_right": { "mappings": { "buttons": {
            "ZR": { "action": "passthrough", "keys": ["fn"] },
            "RStick": { "action": "passthrough", "keys": ["space"] },
            "B": { "action": "passthrough", "keys": ["backspace"] }
          } } } }
        }
        """)

        let incoming = json("""
        {
          "config_version": 9,
          "idle_sleep_minutes": 10,
          "profiles": { "single_right": { "mappings": { "buttons": {
            "ZR": { "action": "passthrough", "keys": ["fn"] },
            "RStick": { "action": "passthrough", "keys": ["ctrl", "x"] },
            "B": { "action": "passthrough", "keys": ["backspace"] },
            "Home": { "action": "passthrough", "keys": ["cmd", "space"] }
          } } } }
        }
        """)

        // Someone who remapped ZR and changed one setting, and left the rest.
        var installed = withButton(baseline, "ZR", ["action": "passthrough", "keys": ["cmd", "shift", "7"]])
        installed["idle_sleep_minutes"] = 30

        let merged = ConfigMerge.merge(installed: installed, incoming: incoming, baseline: baseline)
        let mergedButtons = buttons(merged)

        check(describe(mergedButtons["ZR"]) == describe(["action": "passthrough", "keys": ["cmd", "shift", "7"]]),
              "a button the user remapped is left alone", describe(mergedButtons["ZR"]))
        check(describe(mergedButtons["RStick"]) == describe(["action": "passthrough", "keys": ["ctrl", "x"]]),
              "a button the user never touched takes the new default", describe(mergedButtons["RStick"]))
        check(mergedButtons["Home"] != nil, "a button the new defaults add is added")
        check((merged["idle_sleep_minutes"] as? Int) == 30,
              "a setting the user changed is left alone", describe(merged["idle_sleep_minutes"]))
        check((merged["config_version"] as? Int) == 9,
              "config_version always takes the new value", describe(merged["config_version"]))

        // An install from before any baseline was recorded. Nothing can be
        // shown to be untouched, so nothing may be overwritten.
        let blind = buttons(ConfigMerge.merge(installed: installed, incoming: incoming, baseline: incoming))
        check(describe(blind["ZR"]) == describe(["action": "passthrough", "keys": ["cmd", "shift", "7"]]),
              "without a baseline, the user's mapping still survives", describe(blind["ZR"]))
        check(describe(blind["RStick"]) == describe(["action": "passthrough", "keys": ["space"]]),
              "without a baseline, even an untouched-looking mapping is kept", describe(blind["RStick"]))
        check(blind["Home"] != nil, "without a baseline, new buttons are still added")

        // A mapping this build no longer ships belongs to whoever still uses it.
        let dropped = withButton(baseline, "Capture", ["action": "passthrough", "keys": ["cmd", "5"]])
        let kept = buttons(ConfigMerge.merge(installed: dropped, incoming: incoming, baseline: baseline))
        check(kept["Capture"] != nil, "a button the new defaults do not mention is kept")

        print("")
        if failures.isEmpty {
            print("Config upgrade merge tests passed (\(checks) checks).")
            exit(0)
        }
        print("Config upgrade merge FAILED (\(failures.count) of \(checks)).")
        exit(1)
    }
}
