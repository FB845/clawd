import AppKit
import SwiftUI

/// Renders the menu-bar icon, the app icon, and preview sheets of every look.
enum IconRenderer {
    /// Clawd's silhouette as a template image: body 8 x 6 units, arms 2 x 2, four legs, square eyes cut out.
    static func statusImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 24, height: 16), flipped: true) { _ in
            let u: CGFloat = 2
            NSColor.black.setFill()
            NSRect(x: 2 * u, y: 0, width: 8 * u, height: 6 * u).fill()                    // body
            NSRect(x: 0, y: 2 * u, width: 2 * u, height: 2 * u).fill()                    // arms
            NSRect(x: 10 * u, y: 2 * u, width: 2 * u, height: 2 * u).fill()
            for col in [0, 2, 5, 7] { NSRect(x: (2 + CGFloat(col)) * u, y: 6 * u, width: u, height: 2 * u).fill() }
            NSGraphicsContext.current?.compositingOperation = .clear                       // eyes
            NSRect(x: 3 * u, y: u, width: u, height: u).fill()
            NSRect(x: 8 * u, y: u, width: u, height: u).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        return ctx.makeImage()
    }

    private static func writePNG(_ img: CGImage, _ path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: App icon

    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            if let img = bitmap(px, px, { drawIcon($0, CGFloat(px)) }) {
                writePNG(img, dir + "/icon_\(name).png")
            }
        }
    }

    private static func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
        let inset = s * 0.09
        let r = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = CGPath(roundedRect: r, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.90, blue: 0.84, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let bg = [CGColor(srgbRed: 1.00, green: 0.96, blue: 0.92, alpha: 1),
                  CGColor(srgbRed: 0.97, green: 0.80, blue: 0.69, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: nil, colors: bg, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
        }
        guard let full = SpriteBuilder.build(PetLook()).cgImage(),
              let crop = full.cropping(to: CGRect(x: 4, y: 14, width: 36, height: 24)) else {
            ctx.restoreGState()
            return
        }
        let unit = (r.width * 0.66) / 36
        let w = 36 * unit, h = 24 * unit
        let x = (s - w) / 2, y = s * 0.31
        ctx.saveGState()
        ctx.translateBy(x: s / 2, y: y + unit * 0.5)
        ctx.scaleBy(x: w * 0.52, y: unit * 2.6)
        let sh = [CGColor(srgbRed: 0.45, green: 0.2, blue: 0.1, alpha: 0.32),
                  CGColor(srgbRed: 0.45, green: 0.2, blue: 0.1, alpha: 0)] as CFArray
        if let g = CGGradient(colorsSpace: nil, colors: sh, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        }
        ctx.restoreGState()
        ctx.interpolationQuality = s >= 128 ? .none : .high
        ctx.draw(crop, in: CGRect(x: x, y: y, width: w, height: h))
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.28, blue: 0.18, alpha: 0.18))
        ctx.setLineWidth(max(1, s / 200))
        ctx.strokePath()
    }

    /// Debug render of the details window (light and dark) from the real logs, with every project open.
    static func writeUsageDetail(to path: String, period: UsagePeriod) {
        _ = UsageStore.shared.scanNow()
        var images: [NSBitmapImageRep] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let model = UsageDetailModel()
            model.period = period
            model.load()
            let size = NSSize(width: 620, height: 820)
            let host = NSHostingView(rootView: UsageDetailView(model: model))
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: name)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -3000, y: -3000))   // off in the distance, never seen
            win.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let r = model.report { model.expanded = Set(r.projects.map { $0.id }) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                images.append(rep)
            }
            win.orderOut(nil)
        }
        guard let first = images.first else { return }
        let w = first.pixelsWide, h = first.pixelsHigh
        guard let sheet = bitmap(w * images.count + 20 * (images.count - 1), h, { ctx in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w * images.count + 20, height: h))
            for (i, rep) in images.enumerated() {
                if let cg = rep.cgImage { ctx.draw(cg, in: CGRect(x: i * (w + 20), y: 0, width: w, height: h)) }
            }
        }) else { return }
        writePNG(sheet, path)
    }

    /// Debug render of the menu usage panel in light and dark appearance, from the real logs.
    static func writeUsage(to path: String) {
        let snap = UsageStore.shared.scanNow()
        print("today fresh", snap.today.fresh, "in", snap.today.input, "out", snap.today.output,
              "cw", snap.today.cacheWrite, "cr", snap.today.cacheRead, "week", snap.week.fresh, "month", snap.month.fresh,
              "responses", snap.responses)
        let scale: CGFloat = 2
        var images: [CGImage] = []
        for (name, width) in [(NSAppearance.Name.aqua, UsageView.width), (.darkAqua, UsageView.width + 56)] {
            let v = UsageView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            v.snapshot = snap
            v.frame.size = NSSize(width: width, height: v.intrinsicContentSize.height)
            let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
            let appearance = NSAppearance(named: name)!
            if let img = bitmap(w, h, { ctx in
                ctx.setFillColor(name == .aqua ? CGColor(gray: 0.96, alpha: 1) : CGColor(gray: 0.17, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                appearance.performAsCurrentDrawingAppearance { v.draw(v.bounds) }
                NSGraphicsContext.restoreGraphicsState()
            }) { images.append(img) }
        }
        let W = images.map { $0.width }.reduce(0, +) + 20, H = images.map { $0.height }.max() ?? 0
        guard let sheet = bitmap(W, H, { ctx in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            var x = 0
            for img in images {
                ctx.draw(img, in: CGRect(x: x, y: H - img.height, width: img.width, height: img.height))
                x += img.width + 20
            }
        }) else { return }
        writePNG(sheet, path)
    }

    /// Debug render of the approval card for a couple of typical requests.
    static func writeApproval(to path: String) {
        let samples: [(String, String, String, Int)] = [
            ("Bash", "npm run build && npm test -- --watch=false", "Desktop Pet", 1),
            ("Write", "~/Desktop Pet/Sources/ApprovalPanel.swift", "Desktop Pet", 3),
        ]
        let scale: CGFloat = 2
        var images: [CGImage] = []
        for (tool, detail, project, queued) in samples {
            let a = Approval(tool: tool, detail: detail, project: project, session: "", key: "",
                             responder: Responder(fd: -1))
            let v = ApprovalView(frame: NSRect(x: 0, y: 0, width: ApprovalPanel.width, height: 100))
            v.set(a, queued: queued)
            v.frame.size = v.fittingSize
            v.tailX = ApprovalPanel.width / 2
            Thread.sleep(forTimeInterval: 0.6)   // let the buttons arm
            let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
            if let img = bitmap(w, h, { ctx in
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                v.draw(v.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }) { images.append(img) }
        }
        let W = images.map { $0.width }.reduce(0, +) + 60, H = (images.map { $0.height }.max() ?? 0) + 40
        guard let sheet = bitmap(W, H, { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.29, blue: 0.45, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            var x = 20
            for img in images {
                ctx.draw(img, in: CGRect(x: x, y: H - 20 - img.height, width: img.width, height: img.height))
                x += img.width + 20
            }
        }) else { return }
        writePNG(sheet, path)
    }

    /// Debug render of the menu-bar icon, black on light and white on dark, enlarged.
    static func writeStatus(to path: String) {
        let img = statusImage()
        let scale: CGFloat = 12
        let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
        guard let sheet = bitmap(w * 2 + 30, h + 20, { ctx in
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w + 15, height: h + 20))
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(CGRect(x: w + 15, y: 0, width: w + 15, height: h + 20))
            ctx.interpolationQuality = .none
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            ctx.draw(cg, in: CGRect(x: 10, y: 10, width: w, height: h))
            // White version for the dark half: use the image as a mask.
            ctx.saveGState()
            ctx.clip(to: CGRect(x: w + 25, y: 10, width: w, height: h), mask: cg)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: w + 25, y: 10, width: w, height: h))
            ctx.restoreGState()
        }) else { return }
        writePNG(sheet, path)
    }

    /// Debug sheet of the thinking spinner frames, enlarged.
    static func writeSpinner(to path: String) {
        let cell = 11 * 12, n = 6
        guard let img = bitmap(cell * n + 10 * (n + 1), cell + 20, { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cell * n + 10 * (n + 1), height: cell + 20))
            ctx.interpolationQuality = .none
            for f in 0..<n {
                if let g = Icons.thinking(f) {
                    ctx.draw(g, in: CGRect(x: 10 + f * (cell + 10), y: 10, width: cell, height: cell))
                }
            }
        }) else { return }
        writePNG(img, path)
    }

    // MARK: Preview sheets

    private struct Shot {
        let name: String
        var look: PetLook
        var speech: String?
        var fx: WeatherFX
        var tilt: CGFloat
        var held: Bool
    }

    private static func render(_ v: PetView, scale: CGFloat) -> CGImage? {
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        return bitmap(w, h) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func writePreview(to path: String, dark: Bool) {
        var shots: [Shot] = []
        func add(_ name: String, speech: String? = nil, fx: WeatherFX = .none, tilt: CGFloat = 0, held: Bool = false,
                 _ f: (inout PetLook) -> Void) {
            var l = PetLook()
            f(&l)
            shots.append(Shot(name: name, look: l, speech: speech, fx: fx, tilt: tilt, held: held))
        }
        add("idle") { _ in }
        add("look up-left") { $0.eyeDX = -1; $0.eyeDY = -1 }
        add("walk") { $0.legPhase = 1; $0.lift = 1; $0.eyeDX = 1 }
        add("walk left") { $0.legPhase = 2; $0.lift = 1; $0.eyeDX = 1; $0.facing = -1 }
        add("sleep") { $0.eyeStyle = .closed; $0.bubble = .zzz }
        add("pet") { $0.eyeStyle = .happy; $0.blush = true; $0.mouth = .smile; $0.bubble = .heart }
        add("startle") { $0.eyeStyle = .wide; $0.mouth = .open; $0.bubble = .exclaim }
        add("held", tilt: 18, held: true) { $0.eyeStyle = .wide; $0.legPhase = 3; $0.mouth = .open }
        add("landing") { $0.squash = 2; $0.eyeOpen = 2 }
        add("dance") { $0.eyeStyle = .happy; $0.squash = 1; $0.legPhase = 1; $0.lift = 1; $0.bubble = .note }
        add("dizzy") { $0.eyeStyle = .dizzy; $0.bubble = .dizzy }
        add("wave") { $0.eyeStyle = .happy; $0.wave = 1; $0.mouth = .smile }
        add("thinking") { $0.eyeDX = 1; $0.eyeDY = -1; $0.bubble = .star }
        add("bash") { $0.eyeDX = 1; $0.eyeDY = 1; $0.bubble = .hammer }
        add("edit") { $0.eyeDX = 1; $0.eyeDY = 1; $0.bubble = .pencil }
        add("read") { $0.eyeDX = 1; $0.eyeDY = 1; $0.bubble = .glass }
        add("web") { $0.eyeDX = 1; $0.eyeDY = 1; $0.bubble = .globe }
        add("agent") { $0.eyeDX = 1; $0.eyeDY = 1; $0.bubble = .agent }
        add("needs you", speech: "Needs your OK for Bash") { $0.eyeStyle = .wide; $0.bubble = .question }
        add("done") { $0.eyeStyle = .happy; $0.blush = true; $0.mouth = .smile; $0.bubble = .check }
        add("sulky") { $0.eyeOpen = 2; $0.eyeDX = -1; $0.bubble = .dots }
        add("low battery") { $0.eyeOpen = 2; $0.bubble = .lowbatt }
        add("clipboard") { $0.bubble = .clip }
        add("morning") { $0.bubble = .coffee }
        add("night") { $0.hat = .nightcap; $0.eyeStyle = .closed; $0.bubble = .zzz }
        add("summer") { $0.sunglasses = true }
        add("rain", fx: .rain) { $0.umbrella = true }
        add("snow", fx: .snow) { $0.hat = .beanie; $0.scarf = true }
        add("hot") { $0.sweat = true; $0.mouth = .open }
        add("spring") { $0.hat = .flower }
        add("autumn") { $0.hat = .leaf }
        add("festive") { $0.hat = .santa; $0.eyeStyle = .happy; $0.mouth = .smile }
        add("eating") { $0.eyeStyle = .happy; $0.mouth = .chomp }
        add("eye poke") { $0.eyeOpen = 1 }
        add("weather news", speech: "68°F and partly cloudy in Los Angeles") { _ in }
        add("chomp") { $0.eyeStyle = .happy; $0.mouth = .chomp; $0.facing = -1 }

        let scale: CGFloat = 2
        let cropX: CGFloat = 70, cropW: CGFloat = 220, cropH: CGFloat = 210
        let cols = 6, rows = (shots.count + 1 + cols - 1) / cols
        let cellW = Int(cropW * scale), cellH = Int(cropH * scale)
        let bg = dark ? CGColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1)
                      : CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        let fg = dark ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.4, alpha: 1)
        let sheet = bitmap(cellW * cols, cellH * rows) { ctx in
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
            for (i, shot) in shots.enumerated() {
                let v = PetView(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
                v.tiltTarget = shot.tilt
                v.pivotAtCenter = shot.held
                v.stretchTarget = shot.held ? -0.8 : 0
                v.showShadow = !shot.held
                v.fx = shot.fx
                v.setLook(shot.look)
                v.speech = shot.speech
                v.simulate(1.4)
                guard let img = render(v, scale: scale),
                      let crop = img.cropping(to: CGRect(x: cropX * scale, y: 0, width: cropW * scale, height: cropH * scale))
                else { continue }
                let c = i % cols, r = i / cols
                let x = CGFloat(c * cellW), y = CGFloat((rows - 1 - r) * cellH)
                ctx.draw(crop, in: CGRect(x: x, y: y, width: CGFloat(cellW), height: CGFloat(cellH)))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                (shot.name as NSString).draw(at: NSPoint(x: x + 14, y: y + 10), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: fg,
                ])
                NSGraphicsContext.restoreGraphicsState()
            }
            // Last cell: the toys, including the cookie as it gets eaten.
            let i = shots.count, c = i % cols, r = i / cols
            let x0 = CGFloat(c * cellW), y0 = CGFloat((rows - 1 - r) * cellH)
            ctx.interpolationQuality = .none
            let side = 12 * PetView.pixel * scale * 0.85
            let rowsOfToys: [[CGImage?]] = [BallStyle.allCases.map { Icons.ball($0) },
                                            [Icons.cookie(0), Icons.cookie(1), Icons.cookie(2)]]
            for (row, toys) in rowsOfToys.enumerated() {
                for (k, img) in toys.enumerated() {
                    guard let img = img else { continue }
                    ctx.draw(img, in: CGRect(x: x0 + 24 + CGFloat(k) * (side + 18), y: y0 + 230 - CGFloat(row) * (side + 40),
                                             width: side, height: side))
                }
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("toys" as NSString).draw(at: NSPoint(x: x0 + 14, y: y0 + 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: fg,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
        if let sheet = sheet { writePNG(sheet, path) }
    }
}
