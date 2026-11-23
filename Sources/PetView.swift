import AppKit

enum WeatherFX { case none, rain, snow }

extension Bubble {
    /// Icons that sit inside a thought bubble (everything else is a particle effect or overlay).
    var isThought: Bool {
        switch self {
        case .star, .hammer, .pencil, .glass, .globe, .agent, .dots, .question, .check, .clip, .lowbatt, .coffee:
            return true
        default:
            return false
        }
    }
}

/// Transparent view that renders Clawd: the pixel sprite under a spring-driven transform,
/// a soft ground shadow, particles, thought and speech bubbles, and weather.
final class PetView: NSView {
    static let pixel: CGFloat = 3
    /// Size of the pet's own drawing area. The window can be wider; the pet slides inside it.
    static let petSize = CGSize(width: 360, height: 210)
    static let origin = NSPoint(x: 114, y: 86)   // top-left of the sprite grid, flipped coords
    static let speechFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 12) { return f }
        return base
    }()

    weak var controller: PetController?

    private(set) var look = PetLook()
    private(set) var sprite = PixelGrid(Clawd.gridW, Clawd.gridH)
    private var spriteImage: CGImage?

    var showShadow = true
    var fx: WeatherFX = .none
    var tiltTarget: CGFloat = 0          // degrees, positive leans right
    var stretchTarget: CGFloat = 0       // added to the look's squash (negative stretches)
    var pivotAtCenter = false            // swing around the middle (while held) instead of the feet
    var breath: (amp: CGFloat, period: CGFloat) = (0.018, 3.0)
    var speech: String? { didSet { speechChanged() } }

    private var squash = Spring(k: 260, c: 12)
    private var tilt = Spring(k: 150, c: 9)
    private var hop = Spring(k: 320, c: 20)
    private var side = Spring(x: 1, target: 1, k: 140, c: 22)

    private(set) var clock: CGFloat = 0
    private var particles: [Particle] = []
    private var emitTimer: CGFloat = 0
    private var sweatTimer: CGFloat = 0
    private var weatherAccum: CGFloat = 0

    private var bubble: Bubble = .none
    private var bubbleSince: CGFloat = -10
    private var iconSince: CGFloat = -10
    private var leaving: (bubble: Bubble, since: CGFloat)?
    private var exclaimSince: CGFloat = -10

    private var speechText: String?
    private var speechSince: CGFloat = 0
    private var speechLeaving: CGFloat?

    private var frameParity = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layers
    //
    // On screen the view hosts its own layer tree. The sprite and its shadow are image layers whose
    // squash, tilt, hop, and breathing are plain GPU transforms, so a dancing Clawd costs almost no CPU.
    // Bubbles, particles, and speech are drawn into two overlay layers only while they animate.
    // Offscreen (previews) everything is drawn by `draw(_:)` instead.

    private let petLayer = CALayer()
    private let shadowLayer = CALayer()
    private let backLayer = CALayer()
    private let spriteLayer = CALayer()
    private let frontLayer = CALayer()
    private var painters: [LayerPainter] = []
    private var overlaysWereAnimating = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.isGeometryFlipped = false
        let none: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                        "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        petLayer.actions = none
        petLayer.anchorPoint = .zero
        petLayer.bounds = CGRect(origin: .zero, size: PetView.petSize)
        petLayer.position = .zero
        root.addSublayer(petLayer)
        for l in [shadowLayer, backLayer, spriteLayer, frontLayer] {
            l.actions = none
            petLayer.addSublayer(l)
        }
        setUpThoughtLayers(in: petLayer, actions: none)
        for l in [backLayer, frontLayer] {
            l.frame = petLayer.bounds
            l.contentsScale = 2
        }
        let back = LayerPainter { [weak self] ctx in self?.drawBack(ctx, shadow: false) }
        let front = LayerPainter { [weak self] ctx in self?.drawFront(ctx, thought: false) }
        painters = [back, front]
        backLayer.delegate = back
        frontLayer.delegate = front
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.anchorPoint = .zero
        spriteLayer.position = .zero
        spriteLayer.allowsEdgeAntialiasing = true
        shadowLayer.contents = PetView.shadowImage
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Horizontal position of the pet inside the window. Moving it is a GPU-only layer move,
    /// far cheaper than moving the window itself.
    var offsetX: CGFloat = 0 {
        didSet {
            guard offsetX != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            petLayer.position = CGPoint(x: offsetX, y: 0)
            CATransaction.commit()
        }
    }

    /// True if a screen point is over one of Clawd's painted pixels.
    func isOverPet(_ screenPoint: NSPoint) -> Bool {
        let l = toLocal(screenPoint.x, screenPoint.y)
        guard l.x >= 0, l.y >= 0, l.x < PetView.petSize.width, l.y < PetView.petSize.height else { return false }
        let g = gridPointLocal(l)
        return sprite[g.x, g.y] != 0
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [backLayer, frontLayer] {
            l.contentsScale = scale
            l.setNeedsDisplay()
        }
    }

    /// Soft elliptical shadow, rendered once and stretched by the layer.
    private static let shadowImage: CGImage? = {
        let w = 128, h = 32
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.scaleBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        let colors = [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)] as CFArray
        if let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        }
        return ctx.makeImage()
    }()

    /// Pushes the current sprite, transform, and shadow to the GPU layers.
    private var pushed: (transform: CGAffineTransform, shadow: CGRect, alpha: CGFloat, hidden: Bool, image: CGImage?)?

    private func updateLayers(redrawOverlays: Bool) {
        let px = PetView.pixel
        let w = CGFloat(Clawd.gridW) * px, h = CGFloat(Clawd.gridH) * px, H = PetView.petSize.height
        // Layer space is y-up; the drawing math is y-down. Flip in, transform, flip out.
        let flipSprite = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let toOrigin = CGAffineTransform(translationX: PetView.origin.x, y: PetView.origin.y)
        let flipView = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let t = flipSprite.concatenating(toOrigin).concatenating(bodyTransform()).concatenating(flipView)
        let sh = shadowGeometry()
        let shadowRect = CGRect(x: centerX, y: H - (feetY - 1), width: sh.w, height: sh.h)
        if !redrawOverlays, let p = pushed, p.image === spriteImage, p.hidden == !showShadow,
           abs(p.transform.a - t.a) < 0.002, abs(p.transform.b - t.b) < 0.002, abs(p.transform.c - t.c) < 0.002,
           abs(p.transform.d - t.d) < 0.002, abs(p.transform.tx - t.tx) < 0.25, abs(p.transform.ty - t.ty) < 0.25,
           abs(p.shadow.width - shadowRect.width) < 0.5, abs(p.alpha - sh.alpha) < 0.01 {
            return   // nothing visible changed
        }
        pushed = (t, shadowRect, sh.alpha, !showShadow, spriteImage)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // AppKit flips a flipped view's hosted layer; keep the tree in plain y-up geometry instead,
        // which is what the transforms below are written for.
        if let root = layer, root.isGeometryFlipped { root.isGeometryFlipped = false }
        if let img = spriteImage, spriteLayer.contents as! CGImage? !== img { spriteLayer.contents = img }
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        spriteLayer.setAffineTransform(t)
        shadowLayer.isHidden = !showShadow
        shadowLayer.bounds = CGRect(x: 0, y: 0, width: sh.w, height: sh.h)
        shadowLayer.position = CGPoint(x: shadowRect.minX, y: shadowRect.minY)
        shadowLayer.opacity = Float(sh.alpha)
        if redrawOverlays {
            backLayer.setNeedsDisplay()
            frontLayer.setNeedsDisplay()
        }
        CATransaction.commit()
    }

    /// Debug aid: renders the live layer tree (what is on screen) to a PNG.
    func snapshot(to path: String) {
        let scale: CGFloat = 2
        let w = Int(PetView.petSize.width * scale), h = Int(PetView.petSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.87, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        petLayer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Geometry

    private var centerX: CGFloat { PetView.origin.x + CGFloat(Clawd.gridW) * PetView.pixel / 2 }
    private var feetY: CGFloat { PetView.origin.y + CGFloat(Clawd.floorRow) * PetView.pixel }
    private var headTopY: CGFloat {
        PetView.origin.y + CGFloat(SpriteBuilder.bodyTop(look)) * PetView.pixel - hop.x
    }

    /// Screen position of the pet area's bottom-left corner.
    private var winOrigin: CGPoint {
        guard let f = window?.frame else { return .zero }
        return CGPoint(x: f.minX + offsetX, y: f.minY)
    }
    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: winOrigin.x + p.x, y: winOrigin.y + PetView.petSize.height - p.y)
    }
    private func toLocal(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x - winOrigin.x, y: PetView.petSize.height - (y - winOrigin.y))
    }

    private func bodyTransform() -> CGAffineTransform {
        let feet = CGPoint(x: centerX, y: feetY)
        let b = breath.amp * sin(2 * .pi * clock / max(0.1, breath.period))
        let sx = max(0.6, min(1.4, 1 + 0.07 * squash.x - b * 0.5))
        let sy = max(0.6, min(1.4, 1 - 0.09 * squash.x + b))
        let pivot = pivotAtCenter ? CGPoint(x: feet.x, y: feet.y - 30) : feet
        var t = CGAffineTransform(translationX: 0, y: -hop.x)
        t = t.translatedBy(x: pivot.x, y: pivot.y)
        t = t.rotated(by: tilt.x * .pi / 180)
        t = t.translatedBy(x: feet.x - pivot.x, y: feet.y - pivot.y)
        t = t.scaledBy(x: sx, y: sy)
        t = t.translatedBy(x: -feet.x, y: -feet.y)
        return t
    }

    /// Sprite-grid cell under a point in this view, accounting for squash, tilt, and hop.
    func gridPoint(_ viewPoint: NSPoint) -> (x: Int, y: Int) {
        gridPointLocal(CGPoint(x: viewPoint.x - offsetX, y: viewPoint.y))
    }

    private func gridPointLocal(_ local: CGPoint) -> (x: Int, y: Int) {
        let q = local.applying(bodyTransform().inverted())
        return (Int(floor((q.x - PetView.origin.x) / PetView.pixel)),
                Int(floor((q.y - PetView.origin.y) / PetView.pixel)))
    }

    // MARK: - State in

    func setLook(_ l: PetLook) {
        let built = SpriteBuilder.build(l)
        if built.px != sprite.px || spriteImage == nil {
            sprite = built
            spriteImage = built.cgImage()
        }
        let old = look.bubble
        look = l
        if l.bubble == .exclaim && old != .exclaim { exclaimSince = clock }
        if l.bubble.isThought {
            if !bubble.isThought { bubbleSince = clock; leaving = nil }
            if l.bubble != bubble { iconSince = clock }
            bubble = l.bubble
        } else if bubble.isThought {
            leaving = (bubble, clock)
            bubble = .none
        }
        if [.heart, .zzz, .note].contains(l.bubble) && old != l.bubble { emitTimer = 0 }
        hop.target = CGFloat(l.hop) * 4
        side.target = CGFloat(l.facing)
        needsDisplay = true
    }

    /// Kick the squash spring. Positive squashes (landing), negative stretches (jumping).
    func bounce(_ velocity: CGFloat) {
        squash.v += velocity
    }

    private var lastDT: CGFloat = 1.0 / 60
    private var calmTick = 0
    /// Nothing is moving except breathing; the controller can tick slowly.
    private(set) var isCalm = false

    func step(_ dt: CGFloat) {
        lastDT = dt
        clock += dt
        squash.target = CGFloat(look.squash) * 0.9 + stretchTarget
        squash.step(dt)
        tilt.target = tiltTarget
        tilt.step(dt)
        hop.step(dt)
        side.step(dt)
        runEmitters(dt)
        runWeather(dt)
        stepParticles(dt)
        markDirtyIfChanged()
    }

    /// Moves the GPU layers every frame; repaints the overlays only while something in them animates
    /// (at 30 fps), plus one last time to clear them.
    private func markDirtyIfChanged() {
        let animating = !particles.isEmpty || speechText != nil
            || look.bubble == .dizzy || (look.bubble == .exclaim && clock - exclaimSince < 0.4)
        let thinking = (bubble.isThought || leaving != nil) && speechText == nil
        frameParity = lastDT > 0.025 ? true : !frameParity
        if (thinking || !bubbleLayer.isHidden) && frameParity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if thinking { updateThoughtLayers() } else { for l in trailLayers + [bubbleLayer] { l.isHidden = true } }
            CATransaction.commit()
        }
        let redraw = (animating && frameParity) || (overlaysWereAnimating && !animating)
        overlaysWereAnimating = animating
        // Springs and breathing look smooth at 30 fps; hard bounces and dragging get every frame.
        let fast = pivotAtCenter || abs(squash.v) > 4 || abs(hop.v) > 40 || abs(tilt.v) > 60
        // When only breathing moves things, 10 updates a second is indistinguishable.
        let settled = abs(squash.v) < 0.05 && abs(tilt.v) < 0.5 && abs(hop.v) < 0.5
            && abs(squash.target - squash.x) < 0.01 && abs(tilt.target - tilt.x) < 0.1 && abs(hop.target - hop.x) < 0.1
        calmTick += 1
        isCalm = settled && !animating && !thinking
        let due = settled ? (calmTick % 3 == 0 || lastDT > 0.05) : (frameParity || lastDT > 0.025)
        if redraw || fast || due { updateLayers(redrawOverlays: redraw) }
    }

    /// Runs the animation forward without a window (used to render previews).
    func simulate(_ seconds: CGFloat) {
        var t: CGFloat = 0
        while t < seconds {
            step(1.0 / 60)
            t += 1.0 / 60
        }
    }

    // MARK: - Particles

    private func add(_ p: Particle) {
        particles.append(p)
    }

    enum Burst { case dust(CGFloat), sparkles, crumbs, hearts, stars, sweat, kickPuff }

    func burst(_ b: Burst) {
        let px = PetView.pixel
        let feet = toScreen(CGPoint(x: centerX, y: feetY))
        let head = toScreen(CGPoint(x: centerX, y: headTopY))
        let side = CGFloat(look.facing)
        switch b {
        case .dust(let strength):
            let n = Int(4 + 6 * min(1, strength))
            for i in 0..<n {
                let s: CGFloat = i % 2 == 0 ? 1 : -1
                add(Particle(glyph: .dust, x: feet.x + s * .random(in: 18...40), y: feet.y + 2,
                             vx: s * .random(in: 30...90) * (0.5 + strength), vy: .random(in: 8...30), drag: 3,
                             life: .random(in: 0.45...0.8), scale0: .random(in: 0.8...1.2), scale1: 0.3,
                             alpha: 0.85, fadeIn: 0, fadeOut: 0.4))
            }
        case .sparkles:
            for i in 0..<9 {
                let a = CGFloat(i) / 9 * 2 * .pi + .random(in: -0.2...0.2)
                let sp = CGFloat.random(in: 60...110)
                add(Particle(glyph: i % 2 == 0 ? .sparkle : .sparkleSmall, x: head.x, y: head.y - 18,
                             vx: cos(a) * sp, vy: sin(a) * sp + 20, drag: 2.5,
                             life: .random(in: 0.7...1.1), fadeIn: 0, fadeOut: 0.4))
            }
        case .crumbs:
            let mouth = toScreen(CGPoint(x: centerX + side * 14, y: headTopY + 11 * px))
            for _ in 0..<5 {
                add(Particle(glyph: .crumb, x: mouth.x, y: mouth.y, vx: side * .random(in: 10...60),
                             vy: .random(in: 40...90), ay: -500, life: 0.9, fadeIn: 0, fadeOut: 0.3, floorY: feet.y))
            }
        case .hearts:
            for i in 0..<3 {
                add(Particle(glyph: .heart, x: head.x + CGFloat(i - 1) * 24, y: head.y, vy: .random(in: 40...60),
                             life: 1.2, wobble: 4, wobbleFreq: 1.2, scale0: 0.5, scale1: 1.1, fadeOut: 0.4))
            }
        case .stars:
            for i in 0..<5 {
                let a = CGFloat(i) / 5 * 2 * .pi
                add(Particle(glyph: .star, x: head.x, y: head.y - 10, vx: cos(a) * 70, vy: sin(a) * 50 + 40,
                             ay: -120, drag: 1.5, life: 0.8, fadeIn: 0, fadeOut: 0.3, spin: 6))
            }
        case .sweat:
            for s in [-1, 1] as [CGFloat] {
                add(Particle(glyph: .drop, x: head.x + s * 30, y: head.y - 6, vx: s * 70, vy: 90, ay: -420,
                             life: 0.7, fadeIn: 0, fadeOut: 0.2))
            }
        case .kickPuff:
            let foot = toScreen(CGPoint(x: centerX + side * 40, y: feetY - 6))
            for _ in 0..<5 {
                add(Particle(glyph: .sparkleSmall, x: foot.x, y: foot.y, vx: side * .random(in: 40...120),
                             vy: .random(in: 20...90), drag: 3, life: 0.5, fadeIn: 0, fadeOut: 0.3))
            }
        }
    }

    /// Hot days: a drop beads up just outside the side of the head, slides, then falls and splashes.
    private func runSweat(_ dt: CGFloat) {
        guard look.sweat, look.eyeStyle != .closed else { sweatTimer = 0; return }
        sweatTimer -= dt
        guard sweatTimer <= 0 else { return }
        sweatTimer = .random(in: 1.0...1.7)
        let s: CGFloat = Double.random(in: 0..<1) < 0.7 ? CGFloat(look.facing) : -CGFloat(look.facing)
        let start = toScreen(CGPoint(x: centerX + s * 42, y: headTopY + 10))
        let floor = toScreen(CGPoint(x: 0, y: feetY)).y
        // Slow start reads as the bead forming, then gravity takes over; it grows as it slides.
        add(Particle(glyph: .drop, x: start.x, y: start.y, vx: s * 4, vy: 0, ay: -220, life: 0.9,
                     scale0: 0.65, scale1: 1.35, fadeIn: 0.15, fadeOut: 0.05, floorY: floor))
    }

    private func runEmitters(_ dt: CGFloat) {
        runSweat(dt)
        emitTimer -= dt
        guard emitTimer <= 0 else { return }
        let side = CGFloat(look.facing)
        let head = toScreen(CGPoint(x: centerX, y: headTopY))
        switch look.bubble {
        case .zzz:
            emitTimer = 1.0
            add(Particle(glyph: .z, x: head.x + side * 26, y: head.y + 4, vx: side * 9, vy: 17, life: 2.6,
                         wobble: 4, wobbleFreq: 0.6, scale0: 0.6, scale1: 1.3, fadeOut: 0.8))
        case .heart:
            emitTimer = 0.38
            add(Particle(glyph: .heart, x: head.x + .random(in: -28...28), y: head.y + 2, vy: .random(in: 26...38),
                         life: 1.5, wobble: 5, wobbleFreq: 1.1, phase: .random(in: 0...6), scale0: 0.6, scale1: 1.0,
                         fadeOut: 0.5))
        case .note:
            emitTimer = 0.65
            let s: CGFloat = Bool.random() ? 1 : -1
            add(Particle(glyph: .note, x: head.x + s * 32, y: head.y - 6, vx: s * 10, vy: 24, life: 2.0,
                         wobble: 6, wobbleFreq: 0.9, fadeOut: 0.6))
        case .coffee:
            emitTimer = 0.3
            let r = thoughtRect()
            let mug = toScreen(CGPoint(x: r.midX - 2, y: r.midY - 4))
            add(Particle(glyph: .steam, x: mug.x + .random(in: -4...4), y: mug.y, vy: 16, life: 0.8,
                         wobble: 2, wobbleFreq: 1.5, scale0: 0.6, scale1: 0.9, fadeIn: 0.1, fadeOut: 0.4))
        default:
            emitTimer = 0.1
        }
    }

    private func runWeather(_ dt: CGFloat) {
        guard fx != .none else { return }
        weatherAccum += dt * (fx == .rain ? 45 : 14)
        let floorY = toScreen(CGPoint(x: 0, y: feetY)).y
        let topY = toScreen(CGPoint(x: 0, y: 0)).y
        while weatherAccum >= 1 {
            weatherAccum -= 1
            let sx = toScreen(CGPoint(x: centerX + .random(in: -115...115), y: 0)).x
            if fx == .rain {
                add(Particle(glyph: .rain, x: sx, y: topY + .random(in: 0...30), vx: -35, vy: -460, life: 2,
                             scale0: 0.8, scale1: 0.8, alpha: 0.6, fadeIn: 0.05, fadeOut: 0, front: Bool.random(),
                             floorY: floorY))
            } else {
                let s = CGFloat.random(in: 0.6...1.0)
                add(Particle(glyph: .snow, x: sx, y: topY, vy: -38, life: 8, wobble: 8, wobbleFreq: 0.5,
                             phase: .random(in: 0...6), scale0: s, scale1: s, alpha: 0.95, fadeIn: 0.3, fadeOut: 0.6,
                             front: Bool.random(), floorY: floorY, settle: true))
            }
        }
    }

    /// Screen-space span of the umbrella canopy, so rain splashes on it instead of on Clawd.
    private func umbrellaCanopy() -> (minX: CGFloat, maxX: CGFloat, y: CGFloat)? {
        guard look.umbrella else { return nil }
        let px = PetView.pixel
        let br = Clawd.bodyLeft + Clawd.bodyWidth
        var c0 = br - 13, c1 = br + 10
        if look.facing < 0 { (c0, c1) = (Clawd.gridW - c1, Clawd.gridW - c0) }
        let ly = PetView.origin.y + CGFloat(SpriteBuilder.bodyTop(look) - 10) * px - hop.x
        let a = toScreen(CGPoint(x: PetView.origin.x + CGFloat(c0) * px, y: ly))
        let b = toScreen(CGPoint(x: PetView.origin.x + CGFloat(c1) * px, y: ly))
        return (a.x, b.x, a.y)
    }

    private func splash(_ x: CGFloat, _ y: CGFloat) -> [Particle] {
        [-1, 1].map { (s: CGFloat) in
            Particle(glyph: .splash, x: x, y: y + 1, vx: s * .random(in: 15...40), vy: .random(in: 35...70),
                     ay: -500, life: 0.28, alpha: 0.7, fadeIn: 0, fadeOut: 0.15, front: true)
        }
    }

    private func stepParticles(_ dt: CGFloat) {
        guard !particles.isEmpty else { return }
        var spawned: [Particle] = []
        let canopy = umbrellaCanopy()
        for i in particles.indices {
            var q = particles[i]
            q.age += dt
            if q.resting { particles[i] = q; continue }
            q.vx += q.ax * dt
            q.vy += q.ay * dt
            if q.drag > 0 {
                let k = max(0, 1 - q.drag * dt)
                q.vx *= k
                q.vy *= k
            }
            let prevY = q.y
            q.x += q.vx * dt
            q.y += q.vy * dt
            q.angle += q.spin * dt
            if q.glyph == .rain, let c = canopy, q.x >= c.minX, q.x <= c.maxX, prevY > c.y, q.y <= c.y {
                q.age = q.life
                spawned += splash(q.x, c.y)
            } else if let f = q.floorY, q.y <= f {
                q.y = f
                if q.settle {
                    q.resting = true
                    q.life = min(q.life, q.age + 1.2)
                    q.fadeOut = 1.0
                } else {
                    q.age = q.life
                    if q.glyph == .rain || q.glyph == .drop { spawned += splash(q.x, f) }
                }
            }
            particles[i] = q
        }
        particles.removeAll { $0.age >= $0.life }
        particles += spawned
        if particles.count > 500 { particles.removeFirst(particles.count - 500) }
    }

    // MARK: - Drawing

    /// Offscreen rendering path (previews); on screen the layers above do this work.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawBack(ctx, shadow: true)
        if let img = spriteImage {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.concatenate(bodyTransform())
            drawPixelImage(ctx, img, CGRect(x: PetView.origin.x, y: PetView.origin.y,
                                            width: CGFloat(Clawd.gridW) * PetView.pixel,
                                            height: CGFloat(Clawd.gridH) * PetView.pixel))
            ctx.restoreGState()
        }
        drawFront(ctx)
    }

    private func drawBack(_ ctx: CGContext, shadow: Bool) {
        ctx.interpolationQuality = .none
        if shadow { drawShadow(ctx) }
        drawParticles(ctx, front: false)
        drawDizzy(ctx, front: false)
    }

    private func drawFront(_ ctx: CGContext, thought: Bool = true) {
        ctx.interpolationQuality = .none
        drawDizzy(ctx, front: true)
        drawExclaim(ctx)
        if thought && speechText == nil { drawThought(ctx) }
        drawParticles(ctx, front: true)
        drawSpeech(ctx)
    }

    private func shadowGeometry() -> (w: CGFloat, h: CGFloat, alpha: CGFloat) {
        let k = max(0.35, 1 - max(0, hop.x) / 60)
        return (86 * k * (1 + 0.06 * squash.x), 11 * k, 0.28 * k)
    }

    private func drawShadow(_ ctx: CGContext) {
        guard showShadow, let img = PetView.shadowImage else { return }
        let sh = shadowGeometry()
        ctx.saveGState()
        ctx.setAlpha(sh.alpha)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: centerX - sh.w / 2, y: feetY - 1 - sh.h / 2, width: sh.w, height: sh.h))
        ctx.restoreGState()
    }

    private func weatherFalloff(_ l: CGPoint) -> CGFloat {
        let dx = abs(l.x - centerX) / 115
        return max(0, 1 - dx * dx) * clamp01(l.y / 40)
    }

    private func drawParticles(_ ctx: CGContext, front: Bool) {
        let px = PetView.pixel
        for q in particles where q.front == front {
            guard let img = q.glyph.image else { continue }
            var a = q.alpha
            if q.fadeIn > 0 { a *= min(1, q.age / q.fadeIn) }
            if q.fadeOut > 0 { a *= min(1, max(0, q.life - q.age) / q.fadeOut) }
            let x = q.x + q.wobble * sin(q.phase + q.age * q.wobbleFreq * 2 * .pi)
            let l = toLocal(x, q.y)
            if q.glyph.isWeather { a *= weatherFalloff(l) }
            guard a > 0.01 else { continue }
            let s = q.scale0 + (q.scale1 - q.scale0) * clamp01(q.age / q.life)
            let w = CGFloat(img.width) * px * s, h = CGFloat(img.height) * px * s
            let rect = CGRect(x: (l.x - w / 2).rounded2, y: (l.y - h / 2).rounded2, width: w, height: h)
            ctx.saveGState()
            ctx.setAlpha(a)
            if q.angle != 0 {
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: q.angle)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
            }
            drawPixelImage(ctx, img, rect)
            ctx.restoreGState()
        }
    }

    private func drawDizzy(_ ctx: CGContext, front: Bool) {
        guard look.bubble == .dizzy, let img = Glyph.star.image else { return }
        let px = PetView.pixel
        for i in 0..<3 {
            let a = clock * 4 + CGFloat(i) * 2 * .pi / 3
            let depth = sin(a)
            if (depth >= 0) != front { continue }
            let s = 0.75 + 0.25 * depth
            let w = CGFloat(img.width) * px * s, h = CGFloat(img.height) * px * s
            let x = centerX + 36 * cos(a), y = headTopY - 6 + 7 * depth
            drawPixelImage(ctx, img, CGRect(x: (x - w / 2).rounded2, y: (y - h / 2).rounded2, width: w, height: h))
        }
    }

    private func drawExclaim(_ ctx: CGContext) {
        guard look.bubble == .exclaim, let img = Icons.exclaim else { return }
        let s = easeOutBack(clamp01((clock - exclaimSince) / 0.22))
        guard s > 0.01 else { return }
        let px = PetView.pixel
        let w = CGFloat(img.width) * px, h = CGFloat(img.height) * px
        let bottom = headTopY - 30
        let rect = CGRect(x: (centerX - w / 2 + CGFloat(look.facing) * 24).rounded2, y: (bottom - h).rounded2,
                          width: w, height: h)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.maxY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -rect.midX, y: -rect.maxY)
        drawPixelImage(ctx, img, rect)
        ctx.restoreGState()
    }

    // MARK: Thought bubble

    private func thoughtRect() -> CGRect {
        let px = PetView.pixel
        let bw = 17 * px, bh = 15 * px
        let cx = centerX + side.x * 64
        let bottom = headTopY - 30
        return CGRect(x: (cx - bw / 2).rounded2, y: (bottom - bh).rounded2, width: bw, height: bh)
    }

    /// Everything needed to show the thought bubble this frame, shared by the CPU (preview)
    /// and GPU-layer (on-screen) renderers. Coordinates are y-down view points.
    private struct ThoughtState {
        var alpha: CGFloat
        var rect: CGRect
        var scale: CGFloat
        var bob: CGFloat
        var trail: [(img: CGImage?, center: CGPoint, scale: CGFloat)]
        var icon: (img: CGImage, rect: CGRect, pivot: CGPoint, angle: CGFloat, scale: CGFloat)?
        var typing: [CGRect]
    }

    private func thoughtState() -> ThoughtState? {
        var kind = bubble
        var alpha: CGFloat = 1
        var age = clock - bubbleSince
        if !kind.isThought {
            guard let l = leaving else { return nil }
            let t = (clock - l.since) / 0.18
            if t >= 1 { leaving = nil; return nil }
            kind = l.bubble
            alpha = 1 - t
            age = 10
        }
        let px = PetView.pixel
        let rect = thoughtRect()
        let sd = side.x
        var st = ThoughtState(
            alpha: alpha, rect: rect, scale: easeOutBack(clamp01((age - 0.15) / 0.25)),
            bob: (sin(clock * 2.4) * 1.5).rounded2,
            trail: [
                (Icons.dotSmall, CGPoint(x: centerX + sd * 42, y: headTopY - 9), easeOutBack(clamp01(age / 0.15))),
                (Icons.dotBig, CGPoint(x: centerX + sd * 52, y: headTopY - 21), easeOutBack(clamp01((age - 0.08) / 0.15))),
            ],
            icon: nil, typing: [])

        let c = CGPoint(x: rect.midX, y: rect.midY - px * 0.5)
        let t = clock
        func put(_ img: CGImage?, angle: CGFloat = 0, pivot: CGPoint? = nil, offset: CGPoint = .zero, scale: CGFloat = 1) {
            guard let img = img else { return }
            let w = CGFloat(img.width) * px, h = CGFloat(img.height) * px
            let r = CGRect(x: (c.x - w / 2 + offset.x).rounded2, y: (c.y - h / 2 + offset.y).rounded2, width: w, height: h)
            let pv = pivot.map { CGPoint(x: r.minX + $0.x * px, y: r.minY + $0.y * px) } ?? CGPoint(x: r.midX, y: r.midY)
            st.icon = (img, r, pv, angle, scale)
        }
        switch kind {
        case .star:
            let seq = Icons.thinkingSequence
            put(Icons.thinking(seq[Int(t / 0.12) % seq.count]))
        case .hammer:
            let ph = (t * 1.8).truncatingRemainder(dividingBy: 1)
            let a: CGFloat = ph < 0.7 ? 0.3 - 0.75 * easeOut(ph / 0.7) : -0.45 + 0.75 * ((ph - 0.7) / 0.3)
            put(Icons.hammer, angle: a, pivot: CGPoint(x: 5, y: 9), offset: CGPoint(x: 0, y: 4))
        case .pencil:
            put(Icons.pencil, angle: 0.1 * sin(t * 9), offset: CGPoint(x: 2 * sin(t * 9), y: sin(t * 18)))
        case .glass:
            put(Icons.glass, offset: CGPoint(x: 2.5 * cos(t * 3), y: 2.5 * sin(t * 3)))
        case .globe:
            put(Icons.globe(Int(t * 6) % 16))
        case .agent:
            put(Icons.agent, offset: CGPoint(x: 0, y: -2 * abs(sin(t * 4))))
        case .question:
            put(Icons.question, angle: 0.14 * sin(t * 3), pivot: CGPoint(x: 3.5, y: 9))
        case .check:
            put(Icons.check, scale: easeOutBack(clamp01((t - iconSince) / 0.3)))
        case .clip:
            put(Icons.clip, angle: 0.07 * sin(t * 5))
        case .lowbatt:
            put(Icons.battery(Int(t * 2) % 2 == 0))
        case .coffee:
            put(Icons.coffee, offset: CGPoint(x: 0, y: 3))
        case .dots:
            st.typing = (0..<3).map { i in
                let y = -4 * max(0, sin(t * 6 - CGFloat(i) * 0.9))
                return CGRect(x: c.x - 4 * px + CGFloat(i) * 3 * px, y: (c.y - px + y).rounded2, width: 2 * px, height: 2 * px)
            }
        default:
            break
        }
        return st
    }

    /// CPU path (previews).
    private func drawThought(_ ctx: CGContext) {
        guard let st = thoughtState() else { return }
        let px = PetView.pixel
        ctx.saveGState()
        ctx.setAlpha(st.alpha)
        for (img, c, sc) in st.trail {
            guard let img = img, sc > 0.01 else { continue }
            let w = CGFloat(img.width) * px * sc, h = CGFloat(img.height) * px * sc
            drawPixelImage(ctx, img, CGRect(x: (c.x - w / 2).rounded2, y: (c.y - h / 2).rounded2, width: w, height: h))
        }
        if st.scale > 0.01, let frame = Icons.bubble {
            let anchor = CGPoint(x: st.rect.midX, y: st.rect.maxY)
            ctx.translateBy(x: anchor.x, y: anchor.y + st.bob)
            ctx.scaleBy(x: st.scale, y: st.scale)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
            drawPixelImage(ctx, frame, st.rect)
            ctx.clip(to: st.rect.insetBy(dx: px, dy: px))
            if let ic = st.icon, ic.scale > 0.01 {
                ctx.saveGState()
                ctx.translateBy(x: ic.pivot.x, y: ic.pivot.y)
                ctx.rotate(by: ic.angle)
                ctx.scaleBy(x: ic.scale, y: ic.scale)
                ctx.translateBy(x: -ic.pivot.x, y: -ic.pivot.y)
                drawPixelImage(ctx, ic.img, ic.rect)
                ctx.restoreGState()
            }
            ctx.setFillColor(Palette.cg(C.bubbleInk))
            for r in st.typing { ctx.fill(r) }
        }
        ctx.restoreGState()
    }

    /// GPU path: positions the bubble, icon, and trail layers. Layer space is y-up, so y and angles flip.
    private let bubbleLayer = CALayer()
    private let iconLayer = CALayer()
    private let trailLayers = [CALayer(), CALayer()]
    private let typingLayers = [CALayer(), CALayer(), CALayer()]

    private func setUpThoughtLayers(in root: CALayer, actions: [String: CAAction]) {
        for l in trailLayers + [bubbleLayer] {
            l.actions = actions
            l.magnificationFilter = .nearest
            l.isHidden = true
            root.addSublayer(l)
        }
        bubbleLayer.contents = Icons.bubble
        bubbleLayer.masksToBounds = true
        bubbleLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        iconLayer.actions = actions
        iconLayer.magnificationFilter = .nearest
        iconLayer.allowsEdgeAntialiasing = true
        bubbleLayer.addSublayer(iconLayer)
        for l in typingLayers {
            l.actions = actions
            l.backgroundColor = Palette.cg(C.bubbleInk)
            bubbleLayer.addSublayer(l)
        }
        trailLayers[0].contents = Icons.dotSmall
        trailLayers[1].contents = Icons.dotBig
    }

    private func updateThoughtLayers() {
        let H = PetView.petSize.height
        guard let st = thoughtState() else {
            for l in trailLayers + [bubbleLayer] where !l.isHidden { l.isHidden = true }
            return
        }
        let px = PetView.pixel
        for (i, d) in st.trail.enumerated() {
            let l = trailLayers[i]
            guard let img = d.img, d.scale > 0.01 else { l.isHidden = true; continue }
            l.isHidden = false
            l.opacity = Float(st.alpha)
            l.bounds = CGRect(x: 0, y: 0, width: CGFloat(img.width) * px, height: CGFloat(img.height) * px)
            l.position = CGPoint(x: d.center.x.rounded2, y: (H - d.center.y).rounded2)
            l.setAffineTransform(CGAffineTransform(scaleX: d.scale, y: d.scale))
        }
        guard st.scale > 0.01 else { bubbleLayer.isHidden = true; return }
        let r = st.rect
        bubbleLayer.isHidden = false
        bubbleLayer.opacity = Float(st.alpha)
        bubbleLayer.bounds = CGRect(x: 0, y: 0, width: r.width, height: r.height)
        bubbleLayer.position = CGPoint(x: r.midX, y: H - r.maxY - st.bob)
        bubbleLayer.setAffineTransform(CGAffineTransform(scaleX: st.scale, y: st.scale))
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - r.minX, y: r.maxY - p.y) }
        if let ic = st.icon {
            iconLayer.isHidden = false
            if iconLayer.contents as! CGImage? !== ic.img { iconLayer.contents = ic.img }
            iconLayer.bounds = CGRect(x: 0, y: 0, width: ic.rect.width, height: ic.rect.height)
            iconLayer.anchorPoint = CGPoint(x: (ic.pivot.x - ic.rect.minX) / ic.rect.width,
                                            y: 1 - (ic.pivot.y - ic.rect.minY) / ic.rect.height)
            iconLayer.position = local(ic.pivot)
            iconLayer.setAffineTransform(CGAffineTransform(rotationAngle: -ic.angle).scaledBy(x: ic.scale, y: ic.scale))
        } else {
            iconLayer.isHidden = true
        }
        for (i, l) in typingLayers.enumerated() {
            if i < st.typing.count {
                let tr = st.typing[i]
                l.isHidden = false
                l.frame = CGRect(x: tr.minX - r.minX, y: r.maxY - tr.maxY, width: tr.width, height: tr.height)
            } else {
                l.isHidden = true
            }
        }
    }

    // MARK: Speech bubble

    private func speechChanged() {
        if let s = speech {
            if s != speechText || speechLeaving != nil {
                speechText = s
                speechSince = clock
                speechLeaving = nil
            }
        } else if speechText != nil && speechLeaving == nil {
            speechLeaving = clock
        }
    }

    private func drawSpeech(_ ctx: CGContext) {
        guard let text = speechText else { return }
        var scale = easeOutBack(clamp01((clock - speechSince) / 0.22))
        var alpha: CGFloat = 1
        if let l = speechLeaving {
            let t = (clock - l) / 0.16
            if t >= 1 { speechText = nil; speechLeaving = nil; return }
            scale = 1 - 0.25 * t
            alpha = 1 - t
        }
        guard scale > 0.01 else { return }
        let px = PetView.pixel
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let ink = Palette.colors[Int(C.bubbleInk)]
        let shown = min(text.count, Int((clock - speechSince) * 55))
        let str = NSMutableAttributedString(string: text, attributes: [
            .font: PetView.speechFont, .foregroundColor: ink, .paragraphStyle: para,
        ])
        if shown < text.count {
            let start = text.index(text.startIndex, offsetBy: shown)
            let range = NSRange(start..., in: text)
            str.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
        let size = str.boundingRect(with: NSSize(width: 200, height: 60), options: [.usesLineFragmentOrigin]).size
        let tw = ceil(size.width), th = ceil(min(size.height, 46))
        let bw = ceil((tw + 6 * px) / px) * px, bh = ceil((th + 4 * px) / px) * px
        let tipY = headTopY - 34
        var x = centerX - bw / 2
        x = min(max(x, 4), PetView.petSize.width - bw - 4)
        x = PetView.origin.x + ((x - PetView.origin.x) / px).rounded() * px
        let rect = CGRect(x: x, y: tipY - 3 * px - bh, width: bw, height: bh)
        let tx = PetView.origin.x + ((centerX - PetView.origin.x) / px).rounded() * px

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: tx, y: tipY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -tx, y: -tipY)

        ctx.setFillColor(Palette.cg(C.bubbleInk))
        ctx.fill(rect.insetBy(dx: px, dy: 0))
        ctx.fill(rect.insetBy(dx: 0, dy: px))
        ctx.fill(CGRect(x: tx - 2 * px, y: rect.maxY, width: 4 * px, height: px))
        ctx.fill(CGRect(x: tx - px, y: rect.maxY + px, width: 3 * px, height: px))
        ctx.fill(CGRect(x: tx, y: rect.maxY + 2 * px, width: px, height: px))
        let inner = rect.insetBy(dx: px, dy: px)
        ctx.setFillColor(Palette.cg(C.white))
        ctx.fill(inner.insetBy(dx: px, dy: 0))
        ctx.fill(inner.insetBy(dx: 0, dy: px))
        ctx.setFillColor(Palette.cg(C.panelShade))
        ctx.fill(CGRect(x: inner.minX + px, y: inner.maxY - px, width: inner.width - 2 * px, height: px))
        ctx.fill(CGRect(x: tx - px, y: rect.maxY - px, width: 2 * px, height: 2 * px))
        ctx.fill(CGRect(x: tx, y: rect.maxY + px, width: px, height: px))

        str.draw(with: CGRect(x: rect.minX + 3 * px, y: rect.minY + 2 * px - 1, width: tw, height: th),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        ctx.restoreGState()
    }

    // MARK: - Input

    /// Only the pet's painted pixels are clickable; empty space around it is not.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let g = gridPoint(local)
        return sprite[g.x, g.y] == 0 ? nil : self
    }

    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { controller?.showMenu(event) }
}

private extension CGFloat {
    /// Rounded to the nearest half point (a whole device pixel on Retina).
    var rounded2: CGFloat { (self * 2).rounded() / 2 }
}

/// Paints a CALayer by calling back into `PetView` with a y-down context, like a flipped NSView.
final class LayerPainter: NSObject, CALayerDelegate {
    private let paint: (CGContext) -> Void

    init(_ paint: @escaping (CGContext) -> Void) {
        self.paint = paint
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        ctx.translateBy(x: 0, y: layer.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        paint(ctx)
        NSGraphicsContext.restoreGraphicsState()
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}
