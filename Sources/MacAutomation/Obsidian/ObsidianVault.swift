import Foundation

/// Represents a discovered Obsidian vault on disk.
public struct ObsidianVault: Sendable {
    /// Display name (derived from the folder name).
    public let name: String
    /// Full path to the vault root directory.
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Discovers Obsidian vaults from Obsidian's own config file.
public enum ObsidianVaultDiscovery {

    /// Path to Obsidian's global config that lists all known vaults.
    private static let obsidianConfigPath = NSHomeDirectory()
        + "/Library/Application Support/obsidian/obsidian.json"

    /// Discovers all vaults registered with the Obsidian app.
    /// Reads `~/Library/Application Support/obsidian/obsidian.json`.
    /// Only returns vaults whose directories still exist on disk.
    public static func discoverVaults() -> [ObsidianVault] {
        guard let data = FileManager.default.contents(atPath: obsidianConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: Any] else {
            return []
        }

        var result: [ObsidianVault] = []
        for (_, value) in vaults {
            guard let vaultInfo = value as? [String: Any],
                  let vaultPath = vaultInfo["path"] as? String else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let name = (vaultPath as NSString).lastPathComponent
            result.append(ObsidianVault(name: name, path: vaultPath))
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
