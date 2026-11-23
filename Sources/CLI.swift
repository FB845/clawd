import CryptoKit
import Foundation

/// The command-line side of the app binary: `Clawd hook` is what Claude Code runs, and the other
/// commands let scripts poke Clawd. None of it starts the UI. Always exits 0, and silently does
/// nothing if Clawd isn't running, so a hook can never break Claude Code.
enum CLI {
    static let usage = """
    Talk to the Clawd desktop pet.

      Clawd notify "message"       speech bubble + little hop
      Clawd say "message"          speech bubble only
      Clawd thinking | done | attention | clear
      Clawd tool bash|edit|read|web|agent
      Clawd pet | sleep | wake | snack
      Clawd ball [classic|baseball|basketball|soccer|tennis]
      Clawd connect | disconnect   add or remove the Claude Code hooks
      Clawd hook                   read a Claude Code hook payload on stdin
    """

    private static let simple: Set<String> = ["thinking", "done", "attention", "clear", "pet", "sleep", "wake", "snack"]
    static let commands: Set<String> = simple.union(["hook", "notify", "say", "ball", "tool", "connect", "disconnect", "help"])

    static func run(_ argv: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let cmd = argv.first ?? "help"
        let rest = argv.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        switch cmd {
        case "hook":
            hook()
        case "notify", "say":
            send(["event": cmd, "message": rest.isEmpty ? "Ping!" : rest])
        case "ball":
            var msg: [String: Any] = ["event": "ball"]
            if let kind = rest.split(separator: " ").first { msg["kind"] = kind.lowercased() }
            send(msg)
        case "tool":
            send(["event": "tool", "tool": rest.isEmpty ? "other" : rest])
        case "connect", "disconnect":
            do {
                if cmd == "connect" { try HookInstaller.install() } else { try HookInstaller.remove() }
                print((cmd == "connect" ? "Connected Clawd to" : "Disconnected Clawd from") + " " + HookInstaller.settingsPath)
            } catch {
                FileHandle.standardError.write(("Clawd: " + error.localizedDescription + "\n").data(using: .utf8)!)
            }
        case _ where simple.contains(cmd):
            var msg: [String: Any] = ["event": cmd]
            if !rest.isEmpty { msg["message"] = rest }
            send(msg)
        default:
            print(usage)
        }
        exit(0)
    }

    // MARK: - Socket client

    private static func connectToClawd() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = ControlSocket.address(for: ClawdPaths.socket)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if r != 0 { close(fd); return nil }
        return fd
    }

    private static func writeLine(_ fd: Int32, _ obj: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        data.append(UInt8(ascii: "\n"))
        return data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    private static func send(_ obj: [String: Any]) {
        guard let fd = connectToClawd() else { return }
        _ = writeLine(fd, obj)
        close(fd)
    }

    /// How long a permission request waits for a click on Clawd before Claude Code's own prompt takes over.
    private static var approvalWait: Double {
        Double(ProcessInfo.processInfo.environment["CLAWD_APPROVAL_TIMEOUT"] ?? "") ?? 120
    }

    /// Shows the request on Clawd and waits for a click. Returns true, false, or nil (no answer).
    private static func askClawd(_ payload: [String: Any]) -> Bool? {
        let tool = payload["tool_name"] as? String ?? ""
        let cwd = (payload["cwd"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let req: [String: Any] = [
            "event": "approval_request",
            "tool": prettyTool(tool),
            "detail": String(describe(tool, payload["tool_input"]).prefix(400)),
            "project": (cwd as NSString).lastPathComponent,
            "session": payload["session_id"] as? String ?? "",
            "key": requestKey(payload),
        ]
        guard let fd = connectToClawd() else { return nil }
        defer { close(fd) }
        guard writeLine(fd, req) else { return nil }
        let wait = max(1, approvalWait)
        var tv = timeval(tv_sec: Int(wait), tv_usec: Int32((wait - wait.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buf.last != UInt8(ascii: "\n") {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }   // timed out, or Clawd dropped the card (answered elsewhere, or quit)
            buf.append(chunk, count: n)
            if buf.count > 65536 { return nil }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else { return nil }
        switch obj["decision"] as? String {
        case "allow": return true
        case "deny": return false
        default: return nil
        }
    }

    // MARK: - Describing tool calls

    private static let toolKinds: [String: String] = [
        "Bash": "bash", "PowerShell": "bash",
        "Edit": "edit", "Write": "edit", "MultiEdit": "edit", "NotebookEdit": "edit",
        "Read": "read", "Grep": "read", "Glob": "read", "LS": "read",
        "WebFetch": "web", "WebSearch": "web",
        "Agent": "agent", "Task": "agent",
    ]

    /// Identifies one tool call so Clawd can drop its card once the call is settled elsewhere.
    private static func requestKey(_ payload: [String: Any]) -> String {
        let pair: [Any] = [payload["tool_name"] as? String ?? "", payload["tool_input"] ?? [String: Any]()]
        let blob = (try? JSONSerialization.data(withJSONObject: pair, options: [.sortedKeys])) ?? Data()
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Short, human-readable summary of what the tool is about to do.
    private static func describe(_ tool: String, _ input: Any?) -> String {
        guard let inp = input as? [String: Any] else { return "" }
        let home = NSHomeDirectory()
        func path(_ v: Any?) -> String {
            let p = v as? String ?? ""
            return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        }
        func str(_ k: String) -> String { inp[k].map { "\($0)" } ?? "" }
        switch tool {
        case "Bash", "PowerShell": return str("command")
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": return path(inp["file_path"] ?? inp["notebook_path"])
        case "WebFetch": return str("url")
        case "WebSearch": return str("query")
        case "Glob", "Grep": return "\(str("pattern"))  \(path(inp["path"]))"
        case "Agent", "Task": return str("description")
        default:
            // MCP and others: first non-empty string argument, else the raw arguments.
            for k in inp.keys.sorted() {
                if let v = inp[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
            }
            let raw = (try? JSONSerialization.data(withJSONObject: inp, options: [.sortedKeys])) ?? Data()
            return String((String(data: raw, encoding: .utf8) ?? "").prefix(200))
        }
    }

    private static func prettyTool(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.components(separatedBy: "__")
            return parts.count >= 3 ? parts.last!.replacingOccurrences(of: "_", with: " ") : tool
        }
        return tool.isEmpty ? "this tool" : tool
    }

    /// These "permission" prompts are really questions or plan reviews that need your actual answer.
    /// Allowing them from Clawd would skip that answer, so Clawd only points you to Claude Code.
    private static let needsYou: [String: String] = [
        "AskUserQuestion": "Claude has a question for you",
        "ExitPlanMode": "A plan is ready for your review",
    ]

    // MARK: - Hook

    private static func printJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    private static func hook() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        let ev = payload["hook_event_name"] as? String ?? ""
        let tool = payload["tool_name"] as? String ?? ""
        let session = payload["session_id"] as? String ?? ""
        switch ev {
        case "UserPromptSubmit":
            send(["event": "thinking"])
        case "PreToolUse":
            send(["event": "tool", "tool": toolKinds[tool] ?? "other"])
        case "PostToolUse", "PostToolUseFailure":
            send(["event": "resolved", "session": session, "key": requestKey(payload)])
            send(["event": "thinking"])
        case "PermissionRequest":
            if let why = needsYou[tool] {
                send(["event": "attention", "message": why])
                return   // no decision: Claude Code shows its own prompt
            }
            switch askClawd(payload) {
            case true?:
                printJSON(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                  "decision": ["behavior": "allow"]]])
            case false?:
                printJSON(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                  "decision": ["behavior": "deny", "message": "Denied from Clawd.",
                                                               "interrupt": false]]])
            case nil:
                break   // No answer: print nothing, and Claude Code shows its normal prompt.
            }
        case "Notification":
            let ntype = payload["notification_type"] as? String ?? ""
            let msg = String((payload["message"] as? String ?? "").prefix(140))
            let low = msg.lowercased()
            if ntype == "permission_prompt" || low.contains("permission") {
                send(["event": "attention", "message": "Needs your permission"])
            } else if ntype == "idle_prompt" || low.contains("waiting") {
                send(["event": "attention", "message": "Waiting for you"])
            } else if !msg.isEmpty {
                send(["event": "notify", "message": msg])
            }
        case "Stop":
            send(["event": "done", "session": session])
        case "SessionEnd":
            send(["event": "clear", "session": session])
        default:
            break
        }
    }
}
