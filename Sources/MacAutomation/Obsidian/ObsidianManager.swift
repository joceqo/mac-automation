import AppKit
import Foundation

/// Swift interface for Obsidian vault operations.
/// Works directly with the filesystem — no AppleScript, no Obsidian API.
/// Notes are plain markdown files; vaults are plain directories.
public enum ObsidianManager {

    /// Directories to skip when enumerating notes inside a vault.
    private static let defaultExcludedDirectories: Set<String> = [
        ".git", ".obsidian", ".trash", ".excalidraw", ".mobile"
    ]

    // MARK: - Vault Discovery

    /// Returns all Obsidian vaults discovered on this machine.
    public static func listVaults() -> [ObsidianVault] {
        ObsidianVaultDiscovery.discoverVaults()
    }

    // MARK: - Note Discovery & Search

    /// Lists all markdown notes in a vault.
    /// - Parameters:
    ///   - vault: The vault to scan.
    ///   - excludedDirectories: Additional directory names to skip (merged with defaults).
    /// - Returns: Array of relative paths (e.g. `"Projects/my-note.md"`).
    public static func listNotes(
        in vault: ObsidianVault,
        excludedDirectories: Set<String> = []
    ) -> [String] {
        let allExcluded = defaultExcludedDirectories.union(excludedDirectories)
        let vaultURL = URL(fileURLWithPath: vault.path)
        var notes: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: vault.path + "/", with: "")
            let firstComponent = relativePath.components(separatedBy: "/").first ?? ""

            if allExcluded.contains(firstComponent) {
                enumerator.skipDescendants()
                continue
            }

            if fileURL.pathExtension == "md" {
                notes.append(relativePath)
            }
        }

        return notes.sorted()
    }

    /// Searches notes by filename (case-insensitive substring match).
    /// - Parameters:
    ///   - query: The search string.
    ///   - vault: The vault to search.
    /// - Returns: Matching relative paths, sorted by relevance (title matches first).
    public static func searchNotesByTitle(
        query: String,
        in vault: ObsidianVault
    ) -> [String] {
        let lowerQuery = query.lowercased()
        let allNotes = listNotes(in: vault)

        return allNotes.filter { path in
            let filename = (path as NSString).lastPathComponent.lowercased()
            return filename.contains(lowerQuery)
        }
    }

    /// Searches notes by content (case-insensitive, reads each file).
    /// Stops after finding `maxResults` matches for performance.
    /// - Parameters:
    ///   - query: The search string.
    ///   - vault: The vault to search.
    ///   - maxResults: Maximum number of matches to return. Default 20.
    /// - Returns: Array of `(path, snippet)` tuples.
    public static func searchNotesByContent(
        query: String,
        in vault: ObsidianVault,
        maxResults: Int = 20
    ) -> [(path: String, snippet: String)] {
        let lowerQuery = query.lowercased()
        let allNotes = listNotes(in: vault)
        var results: [(path: String, snippet: String)] = []

        for relativePath in allNotes {
            let fullPath = (vault.path as NSString).appendingPathComponent(relativePath)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

            let lowerContent = content.lowercased()
            guard let range = lowerContent.range(of: lowerQuery) else { continue }

            // Extract a snippet around the match
            let matchIndex = lowerContent.distance(from: lowerContent.startIndex, to: range.lowerBound)
            let snippetStart = max(0, matchIndex - 40)
            let snippetEnd = min(content.count, matchIndex + 80)
            let startIdx = content.index(content.startIndex, offsetBy: snippetStart)
            let endIdx = content.index(content.startIndex, offsetBy: snippetEnd)
            var snippet = String(content[startIdx..<endIdx])
                .replacingOccurrences(of: "\n", with: " ")
            if snippetStart > 0 { snippet = "..." + snippet }
            if snippetEnd < content.count { snippet = snippet + "..." }

            results.append((path: relativePath, snippet: snippet))
            if results.count >= maxResults { break }
        }

        return results
    }

    // MARK: - Create

    /// Creates a new markdown note in a vault.
    /// Creates intermediate directories if needed.
    /// - Parameters:
    ///   - title: The note title (becomes the filename, `.md` is appended).
    ///   - content: The markdown content.
    ///   - folder: Optional subfolder within the vault (e.g. `"Projects"`).
    ///   - vault: The target vault.
    ///   - openInObsidian: Whether to open the note in Obsidian after creation. Default true.
    /// - Returns: The full path to the created file, or nil on failure.
    @discardableResult
    public static func createNote(
        title: String,
        content: String,
        folder: String? = nil,
        in vault: ObsidianVault,
        openInObsidian: Bool = true
    ) -> String? {
        let sanitizedTitle = sanitizeFilename(title)
        let fileName = sanitizedTitle + ".md"

        var directoryPath = vault.path
        if let folder, !folder.isEmpty {
            directoryPath = (vault.path as NSString).appendingPathComponent(folder)
        }

        let filePath = (directoryPath as NSString).appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true
            )
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)

            if openInObsidian {
                openNote(atPath: filePath)
            }

            return filePath
        } catch {
            print("⚠️ Obsidian: failed to create note at \(filePath): \(error)")
            return nil
        }
    }

    // MARK: - Read

    /// Reads the full markdown content of a note.
    /// - Parameters:
    ///   - relativePath: The path relative to the vault root (e.g. `"Projects/my-note.md"`).
    ///   - vault: The vault containing the note.
    /// - Returns: The file contents, or nil if the file doesn't exist.
    public static func readNote(
        relativePath: String,
        in vault: ObsidianVault
    ) -> String? {
        let fullPath = (vault.path as NSString).appendingPathComponent(relativePath)
        return try? String(contentsOfFile: fullPath, encoding: .utf8)
    }

    // MARK: - Append

    /// Appends content to an existing note.
    /// - Parameters:
    ///   - relativePath: The path relative to the vault root.
    ///   - content: The markdown content to append.
    ///   - vault: The vault containing the note.
    /// - Returns: True if the append succeeded.
    @discardableResult
    public static func appendToNote(
        relativePath: String,
        content: String,
        in vault: ObsidianVault
    ) -> Bool {
        let fullPath = (vault.path as NSString).appendingPathComponent(relativePath)

        guard let fileHandle = FileHandle(forWritingAtPath: fullPath) else {
            print("⚠️ Obsidian: file not found at \(fullPath)")
            return false
        }

        defer { fileHandle.closeFile() }
        fileHandle.seekToEndOfFile()
        guard let data = ("\n\n" + content).data(using: .utf8) else { return false }
        fileHandle.write(data)
        return true
    }

    /// Appends content to the daily note via Obsidian's Advanced URI plugin.
    /// Requires the Advanced URI community plugin to be installed in the vault.
    /// - Parameters:
    ///   - content: The text to append.
    ///   - vault: The target vault.
    ///   - heading: Optional heading to append under.
    ///   - silent: Whether to open Obsidian in the background. Default true.
    public static func appendToDailyNote(
        content: String,
        in vault: ObsidianVault,
        heading: String? = nil,
        silent: Bool = true
    ) {
        var urlString = "obsidian://adv-uri?daily=true&mode=append"
            + "&data=\(urlEncode(content))"
            + "&vault=\(urlEncode(vault.name))"

        if let heading, !heading.isEmpty {
            urlString += "&heading=\(urlEncode(heading))"
        }

        if silent {
            urlString += "&openmode=silent"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Open

    /// Opens a note in Obsidian by its full file path.
    public static func openNote(atPath fullPath: String) {
        let urlString = "obsidian://open?path=\(urlEncode(fullPath))"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a vault in Obsidian.
    public static func openVault(_ vault: ObsidianVault) {
        let urlString = "obsidian://open?vault=\(urlEncode(vault.name))"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Tags

    /// Extracts all tags from a note's content (both frontmatter and inline `#tags`).
    /// - Parameters:
    ///   - relativePath: The path relative to the vault root.
    ///   - vault: The vault containing the note.
    /// - Returns: Array of tag strings (without the `#` prefix), deduplicated.
    public static func extractTags(
        relativePath: String,
        in vault: ObsidianVault
    ) -> [String] {
        guard let content = readNote(relativePath: relativePath, in: vault) else { return [] }

        var tags: Set<String> = []

        // Extract from YAML frontmatter
        if content.hasPrefix("---") {
            let parts = content.components(separatedBy: "---")
            if parts.count >= 3 {
                let frontmatter = parts[1]
                // Match tags: [tag1, tag2] or tags:\n  - tag1\n  - tag2
                let tagLinePattern = #"tags?:\s*\[([^\]]+)\]"#
                if let regex = try? NSRegularExpression(pattern: tagLinePattern),
                   let match = regex.firstMatch(
                       in: frontmatter,
                       range: NSRange(frontmatter.startIndex..., in: frontmatter)
                   ),
                   let tagRange = Range(match.range(at: 1), in: frontmatter) {
                    let tagList = frontmatter[tagRange]
                    for tag in tagList.split(separator: ",") {
                        let cleaned = tag.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !cleaned.isEmpty { tags.insert(cleaned) }
                    }
                }

                // Match list-style tags
                let listPattern = #"tags?:\s*\n((?:\s*-\s*.+\n?)+)"#
                if let regex = try? NSRegularExpression(pattern: listPattern),
                   let match = regex.firstMatch(
                       in: frontmatter,
                       range: NSRange(frontmatter.startIndex..., in: frontmatter)
                   ),
                   let listRange = Range(match.range(at: 1), in: frontmatter) {
                    let tagLines = frontmatter[listRange]
                    for line in tagLines.split(separator: "\n") {
                        let cleaned = line.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "- ", with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !cleaned.isEmpty { tags.insert(cleaned) }
                    }
                }
            }
        }

        // Extract inline #tags (not inside code blocks)
        let inlinePattern = #"(?<!\w)#([a-zA-Z][a-zA-Z0-9_/-]*)"#
        if let regex = try? NSRegularExpression(pattern: inlinePattern) {
            let nsRange = NSRange(content.startIndex..., in: content)
            for match in regex.matches(in: content, range: nsRange) {
                if let tagRange = Range(match.range(at: 1), in: content) {
                    tags.insert(String(content[tagRange]))
                }
            }
        }

        return Array(tags).sorted()
    }

    // MARK: - Private Helpers

    private static func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidCharacters).joined(separator: "-")
    }

    private static func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}
