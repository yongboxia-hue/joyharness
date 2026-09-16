import Foundation

/// What an upgrade is allowed to do to a config someone has edited.
///
/// Until 0.2.0 a newer `config_version` replaced the whole file, so anyone who
/// had remapped a button lost it to a timestamped backup they had no reason to
/// look for. The rule now is a three-way merge: a value the user still shares
/// with the defaults they were given moves to the new default, and a value they
/// changed stays exactly as it is.
///
/// Kept apart from RuntimeManager on purpose -- it decides whether someone
/// keeps their mappings, so it is worth being able to test on its own.
enum ConfigMerge {
    /// - Parameters:
    ///   - installed: the config on disk, whatever has become of it.
    ///   - incoming: the defaults this build ships.
    ///   - baseline: the defaults the installed config started life as. With no
    ///     baseline recorded, pass `incoming`: every difference then counts as
    ///     the user's and nothing is overwritten.
    static func merge(
        installed: [String: Any],
        incoming: [String: Any],
        baseline: [String: Any]
    ) -> [String: Any] {
        var result = installed
        for (key, incomingValue) in incoming {
            let baselineValue = baseline[key]

            guard let installedValue = installed[key] else {
                // Something the new defaults add. Nothing of the user's can be
                // standing where it is going.
                result[key] = incomingValue
                continue
            }

            if let installedDictionary = installedValue as? [String: Any],
               let incomingDictionary = incomingValue as? [String: Any] {
                result[key] = merge(
                    installed: installedDictionary,
                    incoming: incomingDictionary,
                    baseline: (baselineValue as? [String: Any]) ?? [:]
                )
                continue
            }

            // The bookkeeping this merge is triggered by, not a setting anyone
            // chose.
            if key == "config_version" {
                result[key] = incomingValue
                continue
            }

            if let baselineValue, equal(installedValue, baselineValue) {
                result[key] = incomingValue
            }
        }
        return result
    }

    /// JSON equality, for the value types a config can hold. Keys the new
    /// defaults no longer mention are not considered here at all: a mapping
    /// this build stopped shipping is still one someone may be using.
    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as [String: Any], right as [String: Any]):
            return left.count == right.count
                && left.allSatisfy { key, value in
                    right[key].map { equal(value, $0) } ?? false
                }
        case let (left as [Any], right as [Any]):
            return left.count == right.count
                && zip(left, right).allSatisfy { equal($0, $1) }
        case let (left as NSObject, right as NSObject):
            return left.isEqual(right)
        default:
            return false
        }
    }
}
