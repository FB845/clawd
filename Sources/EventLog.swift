import Foundation

/// Appends control-socket events to ~/Library/Logs/Clawd.log (kept under ~200 KB) for debugging hooks.
enum EventLog {
    static let path = NSHomeDirectory() + "/Library/Logs/Clawd.log"
    private static var handle: FileHandle?
    private static var written = 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func append(_ line: String) {
        let text = stamp.string(from: Date()) + "  " + line.trimmingCharacters(in: .whitespaces) + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if handle == nil {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 200_000 {
                try? fm.removeItem(atPath: path)
            }
            if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
            handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
            written = 0
        }
        handle?.write(data)
        written += data.count
        if written > 50_000 {   // re-check the size cap now and then
            try? handle?.close()
            handle = nil
        }
    }
}
