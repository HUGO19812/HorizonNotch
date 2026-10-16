import Foundation

/// Connects Claude Code to the island through its hooks.
///
/// Claude Code runs a command on events such as "prompt sent", "tool used",
/// "needs input" and "finished". The hook script below only drops the event
/// JSON it receives on stdin into a folder; the app watches that folder.
/// The script always exits 0 at once, so it can never slow Claude down.
enum ClaudeHooks {
    static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HorizonNotch")
    static let eventFolder = supportFolder.appendingPathComponent("claude-events")
    static let scriptURL = supportFolder.appendingPathComponent("claude-hook.sh")
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]

    private static let script = """
    #!/bin/sh
    # Horizon Notch: hands Claude Code hook events to the island.
    dir="$HOME/Library/Application Support/HorizonNotch/claude-events"
    mkdir -p "$dir" || exit 0
    tmp="$dir/.$$.tmp"
    cat > "$tmp" && mv "$tmp" "$dir/$(date +%s)-$$.json"
    exit 0

    """

    private static var command: String { "\"\(scriptURL.path)\"" }

    static var isInstalled: Bool {
        guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }
    }

    /// Writes the script and adds one hook entry per event to
    /// ~/.claude/settings.json, keeping everything else (a backup is made).
    static func install() throws {
        try FileManager.default.createDirectory(at: eventFolder, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            guard !entries.contains(where: isOurs) else { continue }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if event == "PreToolUse" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in events {
            let entries = ((hooks[event] as? [[String: Any]]) ?? []).filter { !isOurs($0) }
            hooks[event] = entries.isEmpty ? nil : entries
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(settings)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
            ($0["command"] as? String)?.contains("HorizonNotch/claude-hook.sh") == true
        }
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("horizon-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
