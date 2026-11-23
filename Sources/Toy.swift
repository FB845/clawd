import AppKit

enum ToyKind { case ball, snack }

/// Round balls Clawd can play with, each with its own bounce and roll.
enum BallStyle: String, CaseIterable {
    case classic, baseball, basketball, soccer, tennis

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .baseball: return "Baseball"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer ball"
        case .tennis: return "Tennis ball"
        }
    }

    /// Share of speed kept on each bounce.
    var bounce: CGFloat {
        switch self {
        case .classic: return 0.55
        case .baseball: return 0.42
        case .basketball: return 0.75
        case .soccer: return 0.6
        case .tennis: return 0.72
        }
    }

    /// How quickly it stops rolling (per second).
    var friction: CGFloat {
        switch self {
        case .classic: return 1.2
        case .baseball: return 1.7
        case .basketball: return 1.1
        case .soccer: return 0.75
        case .tennis: return 1.4
        }
    }
}

/// Draws a 12x12 pixel toy (rotated as it rolls) with a soft contact shadow.
final class ToyView: NSView {
    weak var toy: Toy?
    var image: CGImage? { didSet { needsDisplay = true } }
    var angle: CGFloat = 0 { didSet { if angle != oldValue { needsDisplay = true } } }
    var contact: CGFloat = 0 { didSet { if abs(contact - oldValue) > 0.01 { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var spriteRect: CGRect {
        let w = 12 * PetView.pixel
        return CGRect(x: (bounds.width - w) / 2, y: bounds.height - Toy.margin - w, width: w, height: w)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let img = image else { return }
        let r = spriteRect
        if contact > 0.01 {
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.maxY + 1)
            ctx.scaleBy(x: 15 * (0.6 + 0.4 * contact), y: 3.5 * (0.6 + 0.4 * contact))
            let colors = [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28 * contact),
                          CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)] as CFArray
            if let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            }
            ctx.restoreGState()
        }
        ctx.interpolationQuality = .none
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: angle)
        ctx.translateBy(x: -r.midX, y: -r.midY)
        drawPixelImage(ctx, img, r)
        ctx.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let r = spriteRect
        return hypot(local.x - r.midX, local.y - r.midY) <= r.width / 2 ? self : nil
    }

    override func mouseDown(with event: NSEvent) { toy?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { toy?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { toy?.mouseUp() }
}

/// A ball or a snack: its own tiny floating window with gravity, bouncing, rolling, and dragging.
final class Toy {
    static let size: CGFloat = 48
    static let margin: CGFloat = 6
    static let radius: CGFloat = 18

    let kind: ToyKind
    let window: NSWindow
    let view: ToyView
    var pos: NSPoint
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var grounded = false
    var dragging = false
    var bites = 0 { didSet { view.image = Icons.cookie(bites) } }
    var style: BallStyle = .classic { didSet { if kind == .ball { view.image = Icons.ball(style) } } }

    private var spin: CGFloat = 0
    private var dragOffset = NSPoint.zero
    private var samples: [(t: TimeInterval, p: NSPoint)] = []

    var centerX: CGFloat { pos.x + Toy.size / 2 }
    var centerY: CGFloat { pos.y + Toy.margin + Toy.radius }
    var bottom: CGFloat { pos.y + Toy.margin }
    var speed: CGFloat { hypot(vx, vy) }
    var isResting: Bool { grounded && !dragging && abs(vx) < 30 }

    init(kind: ToyKind, at center: NSPoint, style: BallStyle = .classic) {
        self.kind = kind
        self.style = style
        pos = NSPoint(x: center.x - Toy.size / 2, y: center.y - Toy.margin - Toy.radius)
        let frame = NSRect(origin: pos, size: NSSize(width: Toy.size, height: Toy.size))
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        view = ToyView(frame: NSRect(origin: .zero, size: frame.size))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.toy = self
        view.image = kind == .ball ? Icons.ball(style) : Icons.cookie(0)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    private var screen: NSScreen {
        let c = NSPoint(x: centerX, y: centerY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func step(_ dt: TimeInterval) {
        let d = CGFloat(dt)
        let vf = screen.visibleFrame
        defer {
            view.contact = dragging ? 0 : max(0, 1 - (bottom - vf.minY) / 50)
            if window.frame.origin != pos { window.setFrameOrigin(pos) }
        }
        guard !dragging else { return }
        let floor = vf.minY - Toy.margin
        vy -= 2600 * d
        pos.x += vx * d
        pos.y += vy * d
        let minX = vf.minX - (Toy.size / 2 - Toy.radius), maxX = vf.maxX - Toy.size / 2 - Toy.radius
        if pos.x < minX { pos.x = minX; vx = -vx * 0.6 } else if pos.x > maxX { pos.x = maxX; vx = -vx * 0.6 }
        if pos.y <= floor {
            pos.y = floor
            if kind == .ball && vy < -150 {
                vy = -vy * style.bounce
                grounded = false
            } else {
                vy = 0
                grounded = true
                if kind == .ball {
                    vx *= max(0, 1 - style.friction * d)
                    if abs(vx) < 4 { vx = 0 }
                } else {
                    vx = 0
                    spin = 0
                }
            }
        } else {
            grounded = false
        }
        // Balls roll; snacks tumble while flying.
        if kind == .ball { view.angle += vx * d / Toy.radius } else { view.angle += spin * d }
    }

    // MARK: Dragging

    func mouseDown() {
        dragging = true
        vx = 0
        vy = 0
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - pos.x, y: m.y - pos.y)
        samples = [(ProcessInfo.processInfo.systemUptime, m)]
    }

    func mouseDragged() {
        guard dragging else { return }
        let m = NSEvent.mouseLocation
        pos = NSPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y)
        window.setFrameOrigin(pos)
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, m))
        samples.removeAll { now - $0.t > 0.12 }
    }

    func mouseUp() {
        guard dragging else { return }
        dragging = false
        grounded = false
        if let first = samples.first, let last = samples.last, last.t - first.t > 0.01 {
            let t = CGFloat(last.t - first.t)
            vx = (last.p.x - first.p.x) / t
            vy = (last.p.y - first.p.y) / t
            let sp = hypot(vx, vy), cap: CGFloat = 2000
            if sp > cap { vx *= cap / sp; vy *= cap / sp }
        }
        spin = kind == .snack ? vx / 40 : 0
    }
}
