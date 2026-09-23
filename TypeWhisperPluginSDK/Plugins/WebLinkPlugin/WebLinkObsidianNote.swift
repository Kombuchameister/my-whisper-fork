import Foundation

struct WebLinkObsidianVault: Identifiable, Equatable, Sendable {
    let path: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum WebLinkObsidianVaultLocator {
    /// Vaults Obsidian knows about, most recently opened first.
    static func detectVaults(homeDirectory: URL) -> [WebLinkObsidianVault] {
        let configURL = homeDirectory
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else {
            return []
        }
        return vaults.values
            .compactMap { info -> (path: String, timestamp: Int)? in
                guard let path = info["path"] as? String else { return nil }
                return (path, info["ts"] as? Int ?? 0)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .map { WebLinkObsidianVault(path: $0.path) }
    }
}

enum WebLinkObsidianNoteError: LocalizedError {
    case vaultNotConfigured
    case vaultMissing(String)
    case noteMissing(String)

    var errorDescription: String? {
        switch self {
        case .vaultNotConfigured:
            webLinkLocalized("Choose an Obsidian vault first.")
        case .vaultMissing(let path):
            String(format: webLinkLocalized("The Obsidian vault folder was not found: %@"), path)
        case .noteMissing(let path):
            String(format: webLinkLocalized("The Obsidian note no longer exists: %@"), path)
        }
    }
}

/// Writes a note named after the web link's title whose body starts with the
/// link, then replaces a placeholder line with the transcript once it exists.
struct WebLinkObsidianNoteWriter: Sendable {
    static let transcribingPlaceholder = "*Transcribing…*"
    private static let maximumFileNameBytes = 200

    let vaultPath: String
    let subfolder: String

    func createNote(title: String, sourceURL: URL) throws -> URL {
        let folder = try folderURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let content = Data("\(sourceURL.absoluteString)\n\n\(Self.transcribingPlaceholder)\n".utf8)
        let baseName = Self.noteFileName(for: title)
        var counter = 1
        while true {
            let name = counter == 1 ? baseName : "\(baseName) \(counter)"
            let noteURL = folder.appendingPathComponent(name).appendingPathExtension("md")
            do {
                try content.write(to: noteURL, options: .withoutOverwriting)
                return noteURL
            } catch CocoaError.fileWriteFileExists {
                counter += 1
            }
        }
    }

    static func completeNote(at noteURL: URL, transcript: String) throws {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        try replacePlaceholder(in: noteURL, with: text)
    }

    static func failNote(at noteURL: URL, message: String) throws {
        let quoted = message
            .split(whereSeparator: \.isNewline)
            .map { "> \($0)" }
            .joined(separator: "\n")
        try replacePlaceholder(
            in: noteURL,
            with: "> [!warning] \(webLinkLocalized("Transcription failed"))\n\(quoted)"
        )
    }

    /// A file name Obsidian accepts and can link to: no path separators, no
    /// characters that break wiki links, and short enough for the file system.
    static func noteFileName(for title: String) -> String {
        var name = title
            .replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        name.removeAll { "*\"<>?#^[]".contains($0) }
        name = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        while name.hasPrefix(".") || name.hasPrefix(" ") {
            name.removeFirst()
        }
        while name.utf8.count > maximumFileNameBytes {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? webLinkLocalized("Web Link") : name
    }

    /// Subfolder components with empty, `.` and `..` parts dropped, so the
    /// note always lands inside the vault.
    static func sanitizedSubfolderComponents(_ subfolder: String) -> [String] {
        subfolder
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func folderURL() throws -> URL {
        let trimmedVault = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVault.isEmpty else {
            throw WebLinkObsidianNoteError.vaultNotConfigured
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedVault, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WebLinkObsidianNoteError.vaultMissing(trimmedVault)
        }
        return Self.sanitizedSubfolderComponents(subfolder).reduce(
            URL(fileURLWithPath: trimmedVault, isDirectory: true)
        ) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Keeps anything the user wrote in the note meanwhile. If the placeholder
    /// was removed, the text is appended instead.
    private static func replacePlaceholder(in noteURL: URL, with text: String) throws {
        guard FileManager.default.fileExists(atPath: noteURL.path) else {
            throw WebLinkObsidianNoteError.noteMissing(noteURL.path)
        }
        var content = try String(contentsOf: noteURL, encoding: .utf8)
        if let range = content.range(of: transcribingPlaceholder) {
            content.replaceSubrange(range, with: text)
        } else {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n\(text)\n"
        }
        try Data(content.utf8).write(to: noteURL, options: .atomic)
    }
}
