import Foundation

/// The open end of a request that is waiting for an answer (a permission request).
/// `reply` writes one JSON line and hangs up; `onClose` fires if the other side gives up first.
final class Responder {
    private var fd: Int32
    private var source: DispatchSourceRead?
    var onClose: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        guard fd >= 0 else { return }   // placeholder (previews)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        // The client sends nothing more, so any readability means it hung up.
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var b = [UInt8](repeating: 0, count: 256)
            if read(self.fd, &b, b.count) <= 0 { self.finish(notify: true) }
        }
        src.resume()
        source = src
    }

    var isOpen: Bool { fd >= 0 }

    func reply(_ obj: [String: Any]) {
        guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        finish(notify: false)
    }

    /// Hang up without answering; the hook then falls back to Claude Code's own prompt.
    func cancel() {
        finish(notify: false)
    }

    private func finish(notify: Bool) {
        guard fd >= 0 else { return }
        source?.cancel()
        source = nil
        close(fd)
        fd = -1
        if notify { onClose?() }
    }
}

/// Tiny Unix-domain-socket server. Clients connect, write one JSON object per line, and hang up.
/// The `bin/clawd` script and Claude Code hooks talk to Clawd through this.
final class ControlSocket {
    static let path = "/tmp/clawd.sock"

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: ([String: Any]) -> Void
    /// Requests that need an answer keep their connection open and come here instead.
    var requestHandler: (([String: Any], Responder) -> Void)?

    init(handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    private static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in bytes.enumerated() where i < 103 { dst[i] = b }
            }
        }
        return addr
    }

    /// True if another Clawd is already serving the control socket.
    static func primaryIsAlive() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(for: ControlSocket.path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return r == 0
    }

    @discardableResult
    func start() -> Bool {
        unlink(ControlSocket.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = ControlSocket.address(for: ControlSocket.path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            fd = -1
            return false
        }
        chmod(ControlSocket.path, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        return true
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.last == UInt8(ascii: "\n") { break }
        }
        if let first = data.split(separator: UInt8(ascii: "\n")).first,
           let obj = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
           obj["event"] as? String == "approval_request", let rh = requestHandler {
            rh(obj, Responder(fd: client))
            return
        }
        close(client)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                handler(obj)
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(ControlSocket.path)
    }
}
