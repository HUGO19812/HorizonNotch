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
    # The app Claude runs in (Terminal, iTerm, VS Code, Claude …) rides along
    # in the file name, for the island's "open" button.
    app=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9.-')
    cat > "$tmp" && mv "$tmp" "$dir/$(date +%s)-$$@$app.json"
    exit 0

    """

    private static var command: String { "\"\(scriptURL.path)\"" }

    // MARK: - Status line (plan usage)

    /// Claude Code hands its status line command the plan limits
    /// (rate_limits: 5-hour and weekly, in %, with their reset times). Our
    /// status line keeps that JSON for the island and then runs the status
    /// line you had before, if any, so yours looks the same as ever.
    static let statusScriptURL = supportFolder.appendingPathComponent("claude-statusline.sh")
    static let statusURL = supportFolder.appendingPathComponent("claude-status.json")
    private static let originalStatusURL = supportFolder.appendingPathComponent("claude-statusline-original")

    private static let statusScript = """
    #!/bin/sh
    # Horizon Notch: keeps Claude Code's plan usage for the island, then
    # shows the status line you had before, if any.
    dir="$HOME/Library/Application Support/HorizonNotch"
    input=$(cat)
    tmp="$dir/.status.$$"
    printf '%s' "$input" > "$tmp" && mv "$tmp" "$dir/claude-status.json"
    if [ -s "$dir/claude-statusline-original" ]; then
      printf '%s' "$input" | sh -c "$(cat "$dir/claude-statusline-original")"
    fi
    exit 0

    """

    private static func isOurStatusLine(_ value: Any?) -> Bool {
        ((value as? [String: Any])?["command"] as? String)?.contains("HorizonNotch/claude-statusline.sh") == true
    }

    /// Puts our status line in, remembering the one that was there.
    private static func addStatusLine(to settings: inout [String: Any]) throws {
        try statusScript.write(to: statusScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusScriptURL.path)
        guard !isOurStatusLine(settings["statusLine"]) else { return }
        var line: [String: Any] = ["type": "command", "command": "\"\(statusScriptURL.path)\""]
        if let previous = settings["statusLine"] as? [String: Any] {
            try ((previous["command"] as? String) ?? "").write(to: originalStatusURL, atomically: true, encoding: .utf8)
            for key in ["padding", "refreshInterval", "hideVimModeIndicator"] where previous[key] != nil {
                line[key] = previous[key]
            }
        } else {
            try? FileManager.default.removeItem(at: originalStatusURL)
        }
        settings["statusLine"] = line
    }

    /// Gives back the status line you had before.
    private static func removeStatusLine(from settings: inout [String: Any]) {
        guard isOurStatusLine(settings["statusLine"]) else { return }
        let original = (try? String(contentsOf: originalStatusURL, encoding: .utf8)) ?? ""
        if original.isEmpty {
            settings["statusLine"] = nil
        } else {
            var line = settings["statusLine"] as? [String: Any] ?? [:]
            line["command"] = original
            settings["statusLine"] = line
        }
        try? FileManager.default.removeItem(at: originalStatusURL)
    }

    static let testSessionID = "horizon-notch-test"

    /// Plays a short fake session (working → done) through the event
    /// folder, exactly the way the hooks deliver it.
    static func sendTest() {
        try? FileManager.default.createDirectory(at: eventFolder, withIntermediateDirectories: true)
        func post(_ name: String, after delay: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let event: [String: Any] = ["session_id": testSessionID, "hook_event_name": name,
                                            "cwd": "/Horizon Notch Test", "tool_name": "Bash",
                                            "tool_input": ["description": L("Test der Verbindung", "Testing the connection")]]
                guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
                let stamp = Int(Date().timeIntervalSince1970)
                try? data.write(to: eventFolder.appendingPathComponent("\(stamp)-test-\(name).json"))
            }
        }
        post("UserPromptSubmit", after: 0)
        post("PreToolUse", after: 0.3)
        post("Stop", after: 4)
        post("SessionEnd", after: 9)
    }

    static var isInstalled: Bool {
        hasEntries && FileManager.default.isExecutableFile(atPath: scriptURL.path)
    }

    /// Our entries are in Claude's settings (the script may still be missing).
    private static var hasEntries: Bool {
        guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }
    }

    /// The hooks point at a script in Application Support. If that folder
    /// was deleted (e.g. when reinstalling), Claude's hooks run into nothing
    /// and the notch stays empty: write the script and folder again.
    static func repairIfNeeded() {
        guard hasEntries else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: eventFolder, withIntermediateDirectories: true)
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        if current != script || !manager.isExecutableFile(atPath: scriptURL.path) {
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }
        // Hooks set up before the plan usage existed get the status line too.
        var settings = readSettings()
        let currentStatus = try? String(contentsOf: statusScriptURL, encoding: .utf8)
        if !isOurStatusLine(settings["statusLine"]) || currentStatus != statusScript {
            try? addStatusLine(to: &settings)
            try? writeSettings(settings)
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
        try addStatusLine(to: &settings)
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
        removeStatusLine(from: &settings)
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
