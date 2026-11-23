import AppKit

/// Token-usage panel shown at the top of Clawd's menu-bar menu.
final class UsageView: NSView {
    static let width: CGFloat = 300

    var snapshot = UsageSnapshot() {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// Called when the header (today) or a project row (last 7 days) is clicked.
    var onOpen: ((UsagePeriod, String?) -> Void)?

    private enum Hit: Equatable { case header, project(Int) }
    private var hoverDay: Int?
    private var hoverHit: Hit?
    private var headerRect = NSRect.zero
    private var projectRects: [NSRect] = []
    private var tracking: NSTrackingArea?

    private let pad: CGFloat = 16
    private let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }
    private let bigFont = UsageView.rounded(26, .bold)
    private let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private let smallFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)

    override var isFlipped: Bool { true }

    // Vertical layout, shared by drawing and sizing.
    private let headerH: CGFloat = 70, gridH: CGFloat = 44, chartH: CGFloat = 92
    private let totalsH: CGFloat = 26, footerH: CGFloat = 32
    private var projectsH: CGFloat { snapshot.topProjects.isEmpty ? 0 : 24 + CGFloat(snapshot.topProjects.count) * 20 + 6 }
    private var modelsH: CGFloat { snapshot.models.isEmpty ? 0 : 22 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: UsageView.width, height: 12 + headerH + gridH + chartH + totalsH + projectsH + modelsH + footerH)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let s = snapshot
        var y: CGFloat = 12
        let w = bounds.width - 2 * pad
        let primary = NSColor.labelColor, secondary = NSColor.secondaryLabelColor, tertiary = NSColor.tertiaryLabelColor

        func text(_ str: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor, right: Bool = false) {
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (str as NSString).size(withAttributes: a)
            (str as NSString).draw(at: NSPoint(x: right ? x - size.width : x, y: y), withAttributes: a)
        }

        // Header: today's fresh tokens, with cache re-reads called out separately. Click for the breakdown.
        headerRect = NSRect(x: 6, y: y - 6, width: bounds.width - 12, height: headerH - 2)
        if hoverHit == .header {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: headerRect, xRadius: 8, yRadius: 8).fill()
        }
        text("TODAY", pad, y, NSFont.systemFont(ofSize: 10, weight: .semibold), secondary)
        text("By project ›", bounds.width - pad, y - 1, NSFont.systemFont(ofSize: 11, weight: .semibold), orange, right: true)
        text(UsageStore.format(s.today.fresh), pad, y + 13, bigFont, primary)
        let bigW = (UsageStore.format(s.today.fresh) as NSString).size(withAttributes: [.font: bigFont]).width
        text("tokens", pad + bigW + 6, y + 27, labelFont, secondary)
        text("plus \(UsageStore.format(s.today.cacheRead)) re-read from cache", pad, y + 48, smallFont, tertiary)
        y += headerH

        // Breakdown grid.
        let cells: [(String, Int)] = [("Input", s.today.input), ("Output", s.today.output),
                                       ("Cache write", s.today.cacheWrite), ("Cache read", s.today.cacheRead)]
        let cw = w / 4
        let box = NSRect(x: pad, y: y, width: w, height: 36)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        for (i, c) in cells.enumerated() {
            let x = pad + CGFloat(i) * cw + 9
            text(c.0, x, y + 4, NSFont.systemFont(ofSize: 9.5, weight: .medium), secondary)
            text(UsageStore.format(c.1), x, y + 17, valueFont, i == 3 ? secondary : primary)
        }
        y += gridH

        // 14-day chart of fresh tokens.
        let chartTop = y
        let hoverText: String = {
            guard let i = hoverDay, i < s.days.count else { return "LAST 14 DAYS" }
            let d = s.days[i]
            let f = DateFormatter()
            f.dateFormat = "EEE MMM d"
            return "\(f.string(from: d.date).uppercased()) · \(UsageStore.format(d.tokens.fresh))"
        }()
        text(hoverText, pad, chartTop, NSFont.systemFont(ofSize: 10, weight: .semibold), secondary)
        let plot = chartRect
        let maxV = CGFloat(max(1, s.days.map { $0.tokens.fresh }.max() ?? 1))
        let n = max(1, s.days.count)
        let slot = plot.width / CGFloat(n)
        for (i, d) in s.days.enumerated() {
            let v = CGFloat(d.tokens.fresh)
            let h = v > 0 ? max(3, plot.height * v / maxV) : 2
            let r = NSRect(x: plot.minX + CGFloat(i) * slot + 2, y: plot.maxY - h, width: slot - 4, height: h)
            let isToday = i == n - 1
            let color: NSColor = v == 0 ? NSColor.quaternaryLabelColor
                : (hoverDay == i || isToday ? orange : orange.withAlphaComponent(0.45))
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
        // Day initials under the first, middle, and last bars.
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        if let first = s.days.first, let last = s.days.last {
            text(df.string(from: first.date), plot.minX, plot.maxY + 3, smallFont, tertiary)
            text("Today", plot.maxX, plot.maxY + 3, smallFont, tertiary, right: true)
            _ = last
        }
        y += chartH

        // Totals.
        text("This week", pad, y + 4, labelFont, secondary)
        text(UsageStore.format(s.week.fresh), pad + 62, y + 3, valueFont, primary)
        text("30 days", pad + w / 2, y + 4, labelFont, secondary)
        text(UsageStore.format(s.month.fresh), pad + w / 2 + 50, y + 3, valueFont, primary)
        y += totalsH

        // Top projects, last 7 days.
        projectRects = []
        if !s.topProjects.isEmpty {
            NSColor.separatorColor.setFill()
            NSRect(x: pad, y: y + 2, width: w, height: 1).fill()
            text("TOP PROJECTS · 7 DAYS", pad, y + 9, NSFont.systemFont(ofSize: 10, weight: .semibold), secondary)
            text("Details ›", bounds.width - pad, y + 9, NSFont.systemFont(ofSize: 10, weight: .semibold), orange, right: true)
            y += 24
            let top = CGFloat(max(1, s.topProjects.first?.tokens ?? 1))
            projectRects = []
            for (i, p) in s.topProjects.enumerated() {
                let row = NSRect(x: 8, y: y - 3, width: bounds.width - 16, height: 20)
                projectRects.append(row)
                if hoverHit == .project(i) {
                    NSColor.labelColor.withAlphaComponent(0.07).setFill()
                    NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
                }
                let name = p.name.count > 20 ? String(p.name.prefix(19)) + "…" : p.name
                text(name, pad, y + 1, labelFont, primary)
                let barX = pad + 128, barW = w - 128 - 46
                NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: y + 5, width: barW, height: 6), xRadius: 3, yRadius: 3).fill()
                orange.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: y + 5, width: max(4, barW * CGFloat(p.tokens) / top), height: 6),
                             xRadius: 3, yRadius: 3).fill()
                text(UsageStore.format(p.tokens), pad + w, y, valueFont, secondary, right: true)
                y += 20
            }
            y += 6
        }

        // Model mix, last 7 days.
        if !s.models.isEmpty {
            let line = s.models.map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: "  ·  ")
            text(line, pad, y, smallFont, secondary)
            y += modelsH
        }

        // Footer: where the numbers come from and how fresh they are.
        NSColor.separatorColor.setFill()
        NSRect(x: pad, y: y + 2, width: w, height: 1).fill()
        let age = Date().timeIntervalSince(s.updated)
        let when = s.updated == .distantPast ? "reading logs…" : (age < 45 ? "updated just now" : "updated \(Int(age / 60)) min ago")
        text("Estimated from Claude Code logs · \(when)", pad, y + 9, smallFont, tertiary)
    }

    private var chartRect: NSRect {
        let top = 12 + headerH + gridH + 18
        return NSRect(x: pad, y: top, width: bounds.width - 2 * pad, height: chartH - 18 - 18)
    }

    // MARK: Hover on the chart

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(at p: NSPoint) -> Hit? {
        if headerRect.contains(p) { return .header }
        if let i = projectRects.firstIndex(where: { $0.contains(p) }) { return .project(i) }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch hit(at: p) {
        case .header?: onOpen?(.today, nil)
        case .project(let i)?:
            if i < snapshot.topProjects.count { onOpen?(.week, snapshot.topProjects[i].name) }
        case nil: break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let region = hit(at: p)
        if region != hoverHit { hoverHit = region; needsDisplay = true }
        let plot = chartRect.insetBy(dx: 0, dy: -10)
        var h: Int?
        if plot.contains(p), !snapshot.days.isEmpty {
            h = min(snapshot.days.count - 1, max(0, Int((p.x - plot.minX) / (plot.width / CGFloat(snapshot.days.count)))))
        }
        if h != hoverDay { hoverDay = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverHit != nil { hoverHit = nil; needsDisplay = true }
        if hoverDay != nil { hoverDay = nil; needsDisplay = true }
    }
}

/// Puts the usage panel at the top of the menu-bar menu and today's count next to the icon.
final class UsageMenuController: NSObject {
    private let item: NSStatusItem
    private let view = UsageView(frame: NSRect(x: 0, y: 0, width: UsageView.width, height: 300))
    private let toggle = NSMenuItem(title: "Show today's tokens in menu bar", action: #selector(toggleTitle), keyEquivalent: "")
    private let details = NSMenuItem(title: "Usage by project…", action: #selector(showDetails), keyEquivalent: "")
    private var showTitle = UserDefaults.standard.object(forKey: "usageInMenuBar") as? Bool ?? true
    private var liveTimer: Timer?
    private var isTracking = false

    init(item: NSStatusItem, menu: NSMenu) {
        self.item = item
        super.init()
        let panel = NSMenuItem()
        view.frame.size = view.intrinsicContentSize
        view.autoresizingMask = [.width]      // fills the menu's width instead of leaving a gap
        panel.view = view
        toggle.target = self
        toggle.state = showTitle ? .on : .off
        details.target = self
        view.onOpen = { [weak self] period, project in self?.openDetails(period, project) }
        menu.insertItem(panel, at: 0)
        menu.insertItem(.separator(), at: 1)
        menu.insertItem(details, at: 2)
        menu.insertItem(toggle, at: 3)
        menu.insertItem(.separator(), at: 4)
        NotificationCenter.default.addObserver(self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.addObserver(self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: menu)

        UsageStore.shared.onChange = { [weak self] snap in self?.apply(snap) }
        UsageStore.shared.start()
        apply(UsageStore.shared.snapshot)
    }

    private func apply(_ snap: UsageSnapshot) {
        view.snapshot = snap
        view.frame.size.height = view.intrinsicContentSize.height   // keep whatever width the menu gave us
        updateTitle()
    }

    private func updateTitle() {
        guard let button = item.button else { return }
        let snap = UsageStore.shared.snapshot
        if showTitle && snap.updated != .distantPast {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + UsageStore.format(snap.today.fresh), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .baselineOffset: 0.5,
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
        button.toolTip = "Clawd · \(UsageStore.format(snap.today.fresh)) tokens today"
    }

    @objc private func showDetails() {
        UsageDetailWindow.shared.show(period: .today)
    }

    /// Closes the menu, then opens the details window (opening it mid-tracking would be swallowed).
    private func openDetails(_ period: UsagePeriod, _ project: String?) {
        item.menu?.cancelTrackingWithoutAnimation()
        DispatchQueue.main.async { [weak self] in
            UsageDetailWindow.shared.show(period: period, focus: project)
            // Backup: if the menu is somehow still open, send it an Escape.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard self?.isTracking == true, let w = NSApp.keyWindow ?? NSApp.windows.first else { return }
                if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: w.windowNumber, context: nil, characters: "\u{1b}",
                                              charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(esc, atStart: true)
                }
            }
        }
    }

    @objc private func toggleTitle() {
        showTitle.toggle()
        UserDefaults.standard.set(showTitle, forKey: "usageInMenuBar")
        toggle.state = showTitle ? .on : .off
        updateTitle()
    }

    /// While the menu is open, pick up new usage quickly and keep the "updated" line honest.
    @objc private func menuOpened() {
        isTracking = true
        UsageStore.shared.refreshNow()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            UsageStore.shared.refreshNow()
            self?.view.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    @objc private func menuClosed() {
        isTracking = false
        liveTimer?.invalidate()
        liveTimer = nil
    }
}
