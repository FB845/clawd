import Foundation

/// Another running Clawd, as last published to the shared registry.
struct Peer {
    let pid: pid_t
    let x: CGFloat       // feet centre, screen coords
    let y: CGFloat       // feet level
    let facing: Int
    let state: String
}

/// Instances share their positions through tiny JSON files in the private runtime folder so two Clawds can meet.
enum PeerRegistry {
    static var dir: String { ClawdPaths.peers }
    static let myPID = getpid()
    private static var myFile: String { "\(dir)/\(myPID).json" }

    static func publish(x: CGFloat, y: CGFloat, facing: Int, state: String) {
        let fm = FileManager.default
        guard ClawdPaths.ensureRuntimeDir() else { return }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["pid": Int(myPID), "x": Double(x), "y": Double(y), "facing": facing,
                                  "state": state, "t": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let tmp = myFile + ".tmp"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        rename(tmp, myFile)
    }

    static func others() -> [Peer] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Peer] = []
        for n in names where n.hasSuffix(".json") {
            let path = "\(dir)/\(n)"
            guard let data = fm.contents(atPath: path),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, let x = o["x"] as? Double, let y = o["y"] as? Double,
                  let t = o["t"] as? Double else { continue }
            if pid == Int(myPID) { continue }
            if now - t > 5 || kill(pid_t(pid), 0) != 0 {
                try? fm.removeItem(atPath: path)
                continue
            }
            out.append(Peer(pid: pid_t(pid), x: x, y: y, facing: o["facing"] as? Int ?? 1, state: o["state"] as? String ?? ""))
        }
        return out
    }

    static func unpublish() {
        try? FileManager.default.removeItem(atPath: myFile)
    }
}
