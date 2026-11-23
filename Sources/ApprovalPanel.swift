import AppKit

/// One pending Claude Code permission request, waiting on an open socket connection.
final class Approval {
    let tool: String
    let detail: String
    let project: String
    let session: String
    let key: String
    let responder: Responder

    init(tool: String, detail: String, project: String, session: String, key: String, responder: Responder) {
        self.tool = tool
        self.detail = detail
        self.project = project
        self.session = session
        self.key = key
        self.responder = responder
    }
}

/// A pixel-style card that floats above Clawd with the request and Allow / Deny buttons.
/// It is its own non-activating panel, so clicking it never steals focus from your work.
final class ApprovalPanel {
    static let width: CGFloat = 280

    let window: NSPanel
    let view: ApprovalView
    var onDecision: ((Bool) -> Void)?

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ApprovalPanel.width, height: 120),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        view = ApprovalView(frame: window.contentLayoutRect)
        window.contentView = view
        view.onDecision = { [weak self] allow in self?.onDecision?(allow) }
    }

    var isVisible: Bool { window.isVisible }

    func show(_ a: Approval, queued: Int) {
        let wasVisible = window.isVisible
        view.set(a, queued: queued)
        var f = window.frame
        f.size = view.fittingSize
        window.setFrame(f, display: true)
        view.frame = NSRect(origin: .zero, size: f.size)
        if !wasVisible {
            view.popIn()
            window.orderFrontRegardless()
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    /// Keeps the card centred above Clawd's head (screen coordinates), clamped to the screen.
    func follow(headX: CGFloat, headTop: CGFloat, screen: NSRect) {
        let size = window.frame.size
        var x = headX - size.width / 2
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        let y = min(headTop + 24, screen.maxY - size.height - 4)
        view.tailX = headX - x
        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
}

final class ApprovalView: NSView {
    var onDecision: ((Bool) -> Void)?
    var tailX: CGFloat = ApprovalPanel.width / 2 { didSet { if abs(tailX - oldValue) > 0.5 { needsDisplay = true } } }

    private var title = ""
    private var detail = ""
    private var footer = ""
    private var shownAt: TimeInterval = 0
    private var hover: Int?      // 0 deny, 1 allow
    private var pressed: Int?
    private var tracking: NSTrackingArea?

    private let px: CGFloat = 3
    private let pad: CGFloat = 14
    private static let armDelay: TimeInterval = 0.5   // ignore clicks right after the card appears

    private static let titleFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13, weight: .bold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 13) { return f }
        return base
    }()
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let footerFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let buttonFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .bold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 12) { return f }
        return base
    }()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var armed: Bool { ProcessInfo.processInfo.systemUptime - shownAt >= ApprovalView.armDelay }

    func set(_ a: Approval, queued: Int) {
        title = "Allow \(a.tool)?"
        detail = a.detail
        var parts: [String] = []
        if !a.project.isEmpty { parts.append(a.project) }
        if queued > 1 { parts.append("1 of \(queued) waiting") }
        footer = parts.joined(separator: "  ·  ")
        shownAt = ProcessInfo.processInfo.systemUptime
        hover = nil
        pressed = nil
        needsDisplay = true
        // Redraw once the buttons arm.
        DispatchQueue.main.asyncAfter(deadline: .now() + ApprovalView.armDelay + 0.02) { [weak self] in
            self?.needsDisplay = true
        }
    }

    func popIn() {
        wantsLayer = true
        guard let layer = layer else { return }
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.6
        a.toValue = 1
        a.damping = 14
        a.stiffness = 260
        a.duration = a.settlingDuration
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.position = CGPoint(x: bounds.midX, y: 0)
        layer.add(a, forKey: "pop")
    }

    // MARK: Layout

    private var textWidth: CGFloat { ApprovalPanel.width - 2 * pad }

    private func detailHeight() -> CGFloat {
        guard !detail.isEmpty else { return 0 }
        let r = (detail as NSString).boundingRect(with: NSSize(width: textWidth, height: 60),
                                                 options: [.usesLineFragmentOrigin], attributes: [.font: ApprovalView.detailFont])
        return min(ceil(r.height), 44)
    }

    private var cardHeight: CGFloat {
        var h = pad + 17
        if !detail.isEmpty { h += 6 + detailHeight() + 8 }
        if !footer.isEmpty { h += 14 }
        h += 10 + 28 + pad
        return h
    }

    override var fittingSize: NSSize { NSSize(width: ApprovalPanel.width, height: cardHeight + 3 * px) }

    private var buttons: (deny: CGRect, allow: CGRect) {
        let y = cardHeight - pad - 28
        let w = (textWidth - 10) / 2
        return (CGRect(x: pad, y: y, width: w, height: 28), CGRect(x: pad + w + 10, y: y, width: w, height: 28))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let card = CGRect(x: 0, y: 0, width: bounds.width, height: cardHeight)

        // Pixel card: ink border with clipped corners, white fill, shaded bottom row, tail toward Clawd.
        ctx.setFillColor(Palette.cg(C.bubbleInk))
        ctx.fill(card.insetBy(dx: px, dy: 0))
        ctx.fill(card.insetBy(dx: 0, dy: px))
        let tx = (min(max(tailX, 5 * px), bounds.width - 5 * px) / px).rounded() * px
        ctx.fill(CGRect(x: tx - 2 * px, y: card.maxY, width: 4 * px, height: px))
        ctx.fill(CGRect(x: tx - px, y: card.maxY + px, width: 3 * px, height: px))
        ctx.fill(CGRect(x: tx, y: card.maxY + 2 * px, width: px, height: px))
        let inner = card.insetBy(dx: px, dy: px)
        ctx.setFillColor(Palette.cg(C.white))
        ctx.fill(inner.insetBy(dx: px, dy: 0))
        ctx.fill(inner.insetBy(dx: 0, dy: px))
        ctx.fill(CGRect(x: tx - px, y: card.maxY - px, width: 2 * px, height: 2 * px))
        ctx.fill(CGRect(x: tx, y: card.maxY + px, width: px, height: px))

        let ink = Palette.colors[Int(C.bubbleInk)]
        var y = pad
        // Little orange accent: a mini Claude spark before the title.
        if let spark = Icons.thinking(5) {
            drawPixelImage(ctx, spark, CGRect(x: pad, y: y + 1, width: 15, height: 15))
        }
        (title as NSString).draw(with: CGRect(x: pad + 21, y: y, width: textWidth - 21, height: 18),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: ApprovalView.titleFont, .foregroundColor: ink])
        y += 17
        if !detail.isEmpty {
            y += 6
            let h = detailHeight()
            let box = CGRect(x: pad - 4, y: y - 3, width: textWidth + 8, height: h + 6)
            ctx.setFillColor(Palette.cg(C.panelShade))
            ctx.fill(box)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byCharWrapping
            (detail as NSString).draw(with: CGRect(x: pad, y: y, width: textWidth, height: h),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: ApprovalView.detailFont, .foregroundColor: ink, .paragraphStyle: para])
            y += h + 8
        }
        if !footer.isEmpty {
            (footer as NSString).draw(at: CGPoint(x: pad, y: y),
                                      withAttributes: [.font: ApprovalView.footerFont, .foregroundColor: NSColor(white: 0.45, alpha: 1)])
        }

        let b = buttons
        drawButton(ctx, b.deny, label: "Deny", fill: C.white, shade: C.panelShade, text: ink, index: 0)
        drawButton(ctx, b.allow, label: "Allow", fill: C.green, shade: C.darkGreen, text: .white, index: 1)
    }

    private func drawButton(_ ctx: CGContext, _ r: CGRect, label: String, fill: UInt8, shade: UInt8, text: NSColor, index: Int) {
        let down = pressed == index && hover == index
        let rect = r.offsetBy(dx: 0, dy: down ? 2 : 0)
        let face = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - (down ? 2 : 0))
        ctx.saveGState()
        if !armed { ctx.setAlpha(0.45) }
        ctx.setFillColor(Palette.cg(C.bubbleInk))
        ctx.fill(face.insetBy(dx: 2, dy: 0))
        ctx.fill(face.insetBy(dx: 0, dy: 2))
        let body = face.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(Palette.cg(shade))
        ctx.fill(body)
        var top = body
        top.size.height -= down ? 0 : 3
        let light = hover == index && armed
        ctx.setFillColor(Palette.cg(fill))
        ctx.fill(top)
        if light {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
            ctx.fill(top)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: ApprovalView.buttonFont, .foregroundColor: text]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: CGPoint(x: top.midX - size.width / 2, y: top.midY - size.height / 2), withAttributes: attrs)
        ctx.restoreGState()
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func button(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        let b = buttons
        if b.deny.contains(p) { return 0 }
        if b.allow.contains(p) { return 1 }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let h = button(at: event)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard armed else { return }
        pressed = button(at: event)
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let h = button(at: event)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard armed, let p = pressed, button(at: event) == p else { return }
        onDecision?(p == 1)
    }
}
