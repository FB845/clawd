import AppKit

/// A horizontal ledge the pet can stand on: the visible top edge of a window.
struct Surface: Equatable {
    let windowID: UInt32
    let y: CGFloat      // Cocoa y (bottom-up) of the window's top edge
    let minX: CGFloat
    let maxX: CGFloat
}

/// Scans on-screen windows (no permissions needed for bounds) and computes
/// which parts of their top edges are not hidden behind windows in front.
enum SurfaceScanner {
    static func scan(headroom: CGFloat) -> [Surface] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = Int(getpid())
        var rects: [(id: UInt32, rect: NSRect)] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.5,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let wd = b["Width"] as? Double, let h = b["Height"] as? Double,
                  wd >= 180, h >= 100 else { continue }
            let rect = NSRect(x: x, y: primaryHeight - y - h, width: wd, height: h)
            rects.append((UInt32(id), rect))
        }

        var out: [Surface] = []
        for (i, r) in rects.enumerated() {   // list is front-to-back
            let top = r.rect.maxY
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(r.rect) }) else { continue }
            if top > screen.visibleFrame.maxY - headroom { continue }
            var segs: [(CGFloat, CGFloat)] = [(r.rect.minX, r.rect.maxX)]
            for j in 0..<i {
                let f = rects[j].rect
                if f.minY <= top + headroom && f.maxY >= top - 4 {
                    segs = subtract(segs, f.minX, f.maxX)
                }
            }
            for s in segs where s.1 - s.0 >= 90 {
                out.append(Surface(windowID: r.id, y: top, minX: s.0, maxX: s.1))
            }
        }
        return out
    }

    /// Cheap single-window lookup used while standing on that window: its top edge and x span.
    static func track(_ id: UInt32) -> (y: CGFloat, minX: CGFloat, maxX: CGFloat)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let w = list.first, (w[kCGWindowIsOnscreen as String] as? Bool) ?? true,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let wd = b["Width"] as? Double, let h = b["Height"] as? Double else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        _ = h
        return (primaryHeight - y, x, x + wd)
    }

    private static func subtract(_ segs: [(CGFloat, CGFloat)], _ a: CGFloat, _ b: CGFloat) -> [(CGFloat, CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        for s in segs {
            if b <= s.0 || a >= s.1 { out.append(s); continue }
            if a > s.0 { out.append((s.0, a)) }
            if b < s.1 { out.append((b, s.1)) }
        }
        return out
    }
}
