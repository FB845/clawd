import Foundation

/// Adds or removes Clawd's hooks in `~/.claude/settings.json`, leaving everything else as it was.
///
/// Each hook runs this app's own binary as `Clawd hook`, so nothing else (Python, scripts) needs
/// to be installed. A copy of the previous file is kept as `settings.json.clawd-backup`.
enum HookInstaller {
    enum Status { case notInstalled, installed, needsUpdate }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification",
                         "PermissionRequest", "Stop", "SessionEnd"]

    static var settingsPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json") }
    static var claudeDirExists: Bool {
        FileManager.default.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude"))
    }

    /// The exact command Claude Code should run, pointing at wherever this copy of the app lives.
    static var command: String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "\"\(exe)\" hook"
    }

    /// Recognises Clawd hooks from any install: this app, a moved copy, or the old `bin/clawd` script.
    private static func isOurs(_ h: [String: Any]) -> Bool {
        guard h["type"] as? String == "command", let cmd = h["command"] as? String else { return false }
        return cmd.lowercased().hasSuffix("/clawd\" hook")
    }

    private static func ourHooks(_ entry: Any) -> [[String: Any]] {
        ((entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).filter(isOurs)
    }

    static func status() -> Status {
        guard let data = load(), let hooks = data["hooks"] as? [String: Any] else { return .notInstalled }
        var found = 0, current = 0
        for ev in events {
            for entry in hooks[ev] as? [Any] ?? [] {
                for h in ourHooks(entry) {
                    found += 1
                    if h["command"] as? String == command { current += 1 }
                }
            }
        }
        if found == 0 { return .notInstalled }
        return current == events.count && found == events.count ? .installed : .needsUpdate
    }

    static func install() throws { try rewrite(adding: true) }
    static func remove() throws { try rewrite(adding: false) }

    // MARK: -

    private static func load() -> [String: Any]? {
        guard let raw = FileManager.default.contents(atPath: settingsPath) else { return nil }
        return try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
    }

    private static func rewrite(adding: Bool) throws {
        let fm = FileManager.default
        var data: [String: Any] = [:]
        if let raw = fm.contents(atPath: settingsPath), !raw.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw Failure(errorDescription: "\(settingsPath) isn't plain JSON, so Clawd left it alone. "
                              + "Fix or remove the file and try again.")
            }
            data = obj
            try? fm.removeItem(atPath: settingsPath + ".clawd-backup")
            try fm.copyItem(atPath: settingsPath, toPath: settingsPath + ".clawd-backup")
        }
        var hooks = data["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            // Take out only Clawd's own hooks; anything sharing an entry with them stays.
            var entries: [Any] = (hooks[ev] as? [Any] ?? []).compactMap { entry in
                guard var e = entry as? [String: Any], let hs = e["hooks"] as? [[String: Any]], !ourHooks(entry).isEmpty
                else { return entry }
                let kept = hs.filter { !isOurs($0) }
                if kept.isEmpty { return nil }
                e["hooks"] = kept
                return e
            }
            if adding {
                let hook: [String: Any] = ev == "PermissionRequest"
                    // Waits for a click on Clawd, so it must run in the foreground.
                    ? ["type": "command", "command": command, "timeout": 180]
                    : ["type": "command", "command": command, "timeout": 5, "async": true]
                entries.append(["hooks": [hook]])
            }
            if entries.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = entries }
        }
        if hooks.isEmpty { data.removeValue(forKey: "hooks") } else { data["hooks"] = hooks }

        try fm.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var out = try JSONSerialization.data(withJSONObject: data,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(UInt8(ascii: "\n"))
        // Write through a symlinked settings file (dotfile repos) and keep its permissions.
        let target = URL(fileURLWithPath: settingsPath).resolvingSymlinksInPath()
        let perms = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try out.write(to: target, options: .atomic)
        if let perms = perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path) }
    }
}
