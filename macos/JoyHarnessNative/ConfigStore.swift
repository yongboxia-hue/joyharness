import Foundation

enum ConfigStoreError: LocalizedError {
    case invalidRoot
    case missingProfiles
    case missingProfile(String)
    /// The new config was written, the runtime would not take it, AND putting
    /// the old file back failed too -- the only case where the user's settings
    /// are actually at risk.
    case rollbackFailed(saveError: Error, rollbackError: Error)

    var errorDescription: String? {
        switch self {
        case .invalidRoot: return "配置文件格式不正确。"
        case .missingProfiles: return "配置中缺少手柄 profile。"
        case .missingProfile(let name): return "配置中缺少 \(name) profile。"
        case .rollbackFailed(let saveError, let rollbackError):
            return "改动没有生效，原来的设置也没能恢复（\(saveError.localizedDescription) / "
                + "\(rollbackError.localizedDescription)）。备份在 config/backups 里。"
        }
    }
}

actor ConfigStore {
    private let configURL: URL
    private let runtimeClient: RuntimeClient

    init(configURL: URL, runtimeClient: RuntimeClient) {
        self.configURL = configURL
        self.runtimeClient = runtimeClient
    }

    func loadJSONObject() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        return try validate(data)
    }

    func save(_ object: [String: Any]) async throws {
        let newData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        _ = try validate(newData)
        let oldData = try Data(contentsOf: configURL)
        _ = try validate(oldData)

        try createBackup(from: oldData)
        try newData.write(to: configURL, options: .atomic)
        do {
            try await runtimeClient.reloadConfig()
        } catch {
            // Putting the file back is what "rollback" means, and it is the
            // only part that can actually lose the user's settings. Telling the
            // runtime about it afterwards is best effort: when the runtime is
            // the thing that stopped answering, it is also not running the
            // config we just withdrew, so there is nothing left to undo.
            //
            // Treating that second notify as part of the rollback is why a save
            // attempted while the service was down reported "自动恢复失败" on
            // top of a rollback that had in fact succeeded -- and said it twice,
            // because both halves carried the same timeout.
            do {
                try oldData.write(to: configURL, options: .atomic)
            } catch let rollbackError {
                throw ConfigStoreError.rollbackFailed(saveError: error, rollbackError: rollbackError)
            }
            try? await runtimeClient.reloadConfig()
            throw error
        }
    }

    private func validate(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigStoreError.invalidRoot
        }
        guard let profiles = root["profiles"] as? [String: Any] else {
            throw ConfigStoreError.missingProfiles
        }
        for name in ["single_left", "single_right"] {
            guard let profile = profiles[name] as? [String: Any],
                  let mappings = profile["mappings"] as? [String: Any],
                  mappings["buttons"] is [String: Any] else {
                throw ConfigStoreError.missingProfile(name)
            }
        }
        return root
    }

    private func createBackup(from data: Data) throws {
        let backupURL = configURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "\(configURL.deletingPathExtension().lastPathComponent)-\(formatter.string(from: Date())).json"
        try data.write(to: backupURL.appendingPathComponent(filename), options: .atomic)
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var result = lhs
    result.append(rhs)
    return result
}
