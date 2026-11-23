import Foundation

/// Where Clawd keeps its control socket and peer files: a folder only this user can open.
///
/// These used to live in /tmp, which every account on the Mac shares. Approvals travel over the
/// socket, so it belongs in a private folder.
enum ClawdPaths {
    static let runtimeDir: String = {
        let support = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Clawd")
        // A Unix socket path must fit in 104 bytes; very long home folders fall back to a per-user /tmp folder.
        if (support + "/clawd.sock").utf8.count < 100 { return support }
        return "/tmp/clawd-\(getuid())"
    }()

    static var socket: String { runtimeDir + "/clawd.sock" }
    static var peers: String { runtimeDir + "/peers" }

    /// Creates the folder if needed and makes sure it is a real directory, owned by this user, mode 0700.
    @discardableResult
    static func ensureRuntimeDir() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(runtimeDir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 { chmod(runtimeDir, 0o700) }
        return true
    }
}
