import AppKit

/// Indexed colours shared by all the pixel art. Index 0 is transparent.
enum Palette {
    static let hex: [UInt32] = [
        0x000000, 0xD97757, 0x5E2817, 0x1F1A17, 0xFFFFFF, 0xF2899A, 0xE8486A, 0x8A9BC2, 0xF5B84C, 0xE99B7F,
        0x5B6EE1, 0x46B06A, 0xC9A06B, 0xF7F5EF, 0xE04848, 0x8A8A95, 0xA04A30, 0xBE6346, 0xA9553A, 0xF4BBA3,
        0xE28D6F, 0xA24E34, 0x6B2E1C, 0x3E4FB8, 0xA82E35, 0xC9CCD6, 0x4A4A55, 0xFFD34D, 0xB8783E, 0x5A3420,
        0xE2B97A, 0x6FB6F0, 0x2E7D4A, 0xF7A1C4, 0xF08A3C, 0xEAF2FF, 0x3B2F2A, 0x8FA3FF, 0xD4A63A, 0xECE6E0,
        0x8E5A2C, 0xE2772B, 0xA9521B, 0xCFE33F, 0x97AE26,
    ]
    static let colors: [NSColor] = hex.enumerated().map { i, h in
        if i == 0 { return NSColor.clear }
        return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                       blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
    static func cg(_ i: UInt8) -> CGColor { colors[Int(i)].cgColor }
}

/// Named palette indices.
enum C {
    static let base: UInt8 = 1, outline: UInt8 = 2, ink: UInt8 = 3, white: UInt8 = 4, blush: UInt8 = 5
    static let heart: UInt8 = 6, zzz: UInt8 = 7, gold: UInt8 = 8, light: UInt8 = 9, blue: UInt8 = 10
    static let green: UInt8 = 11, tan: UInt8 = 12, paper: UInt8 = 13, red: UInt8 = 14, grey: UInt8 = 15
    static let outlineLight: UInt8 = 16, shade: UInt8 = 17, deepShade: UInt8 = 18, specular: UInt8 = 19
    static let midLight: UInt8 = 20, leg: UInt8 = 21, legDark: UInt8 = 22, darkBlue: UInt8 = 23
    static let darkRed: UInt8 = 24, lightGrey: UInt8 = 25, darkGrey: UInt8 = 26, yellow: UInt8 = 27
    static let cookie: UInt8 = 28, chocolate: UInt8 = 29, lightWood: UInt8 = 30, water: UInt8 = 31
    static let darkGreen: UInt8 = 32, petal: UInt8 = 33, leafOrange: UInt8 = 34, snow: UInt8 = 35
    static let bubbleInk: UInt8 = 36, lightBlue: UInt8 = 37, darkGold: UInt8 = 38, panelShade: UInt8 = 39
    static let cookieRim: UInt8 = 40, hoops: UInt8 = 41, hoopsShade: UInt8 = 42
    static let tennis: UInt8 = 43, tennisShade: UInt8 = 44
}

/// Layout of the pet's pixel grid. The body follows the Claude Code mascot:
/// a wide block with tall eyes, little side arms, and four stubby legs.
enum Clawd {
    /// One "unit" is the official mascot's eye: a square. Everything else is a whole number of units.
    /// Body 8 x 6, arms 2 x 2 (starting 2 down), eyes 1 x 1 (1 in, 1 down), legs 1 x 2 at columns 0, 2, 5, 7.
    static let unit = 3                        // grid cells per official unit
    static let gridW = 44, gridH = 40, floorRow = 38
    static let bodyLeft = 10
    static let bodyWidth = 8 * unit, bodyHeight = 6 * unit
    static let legWidth = unit, legHeight = 2 * unit
    static let armSize = 2 * unit
    static let legOffsets = [0, 2, 5, 7].map { $0 * unit }
    /// Flat, single-colour art like the official 2D mascot. Set to true to bring back the outline,
    /// body shading, and highlights.
    static let shaded = false
}

enum EyeStyle { case normal, wide, happy, closed, dizzy }
enum Mouth { case none, smile, open, chomp }
enum Bubble {
    case none, zzz, heart, star, exclaim, note, dizzy
    case hammer, pencil, glass, globe, agent, dots, question, check
    case clip, lowbatt, coffee
}
enum Hat { case none, nightcap, santa, beanie, flower, leaf }

/// Everything that describes one animation frame of the pet.
struct PetLook {
    var eyeStyle: EyeStyle = .normal
    var eyeOpen = 3          // 3 open, 2 half, 1 slit, 0 closed (blink)
    var eyeDX = 0            // gaze offset, -1...1 (before mirroring)
    var eyeDY = 0
    var legPhase = 0         // 0 standing, 1 / 2 alternate steps, 3 airborne
    var squash = 0           // -1 stretch ... 2 very squashed (rendered as a smooth spring)
    var lift = 0             // body raised by N pixels (walking bob)
    var hop = 0              // little jump, rendered as a smooth offset
    var facing = 1           // 1 right, -1 left
    var mouth: Mouth = .none
    var blush = false
    var hat: Hat = .none
    var sunglasses = false
    var scarf = false
    var sweat = false
    var umbrella = false
    var shiver = 0           // horizontal jitter in pixels
    var wave = 0             // 0 none, 1 arm up, 2 arm out
    var bubble: Bubble = .none
    var bubblePhase = 0
}

/// A small indexed-colour pixel grid. y = 0 is the top row.
struct PixelGrid {
    let w: Int
    let h: Int
    var px: [UInt8]

    init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
        px = [UInt8](repeating: 0, count: w * h)
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get {
            guard x >= 0, y >= 0, x < w, y < h else { return 0 }
            return px[y * w + x]
        }
        set {
            guard x >= 0, y >= 0, x < w, y < h else { return }
            px[y * w + x] = newValue
        }
    }

    mutating func fill(_ x: Int, _ y: Int, _ fw: Int, _ fh: Int, _ c: UInt8) {
        guard fw > 0, fh > 0 else { return }
        for yy in y..<(y + fh) { for xx in x..<(x + fw) { self[xx, yy] = c } }
    }

    mutating func stamp(_ rows: [String], at x: Int, _ y: Int, color: UInt8) {
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() where ch != "." { self[x + dx, y + dy] = color }
        }
    }

    mutating func stamp(_ rows: [String], at x: Int, _ y: Int, colors: [Character: UInt8]) {
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() {
                if let c = colors[ch] { self[x + dx, y + dy] = c }
            }
        }
    }

    mutating func overlay(_ other: PixelGrid) {
        for i in 0..<min(px.count, other.px.count) where other.px[i] != 0 { px[i] = other.px[i] }
    }

    func mirrored() -> PixelGrid {
        var out = PixelGrid(w, h)
        for y in 0..<h { for x in 0..<w { out[w - 1 - x, y] = self[x, y] } }
        return out
    }

    func shifted(dx: Int) -> PixelGrid {
        guard dx != 0 else { return self }
        var out = PixelGrid(w, h)
        for y in 0..<h { for x in 0..<w { out[x, y] = self[x - dx, y] } }
        return out
    }

    /// One image pixel per grid cell; scale it up with interpolation turned off.
    func cgImage() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let c = Int(px[i])
            if c == 0 { continue }
            let v = Palette.hex[c]
            bytes[i * 4] = UInt8((v >> 16) & 0xFF)
            bytes[i * 4 + 1] = UInt8((v >> 8) & 0xFF)
            bytes[i * 4 + 2] = UInt8(v & 0xFF)
            bytes[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Builds the pet procedurally from a `PetLook`: silhouette, lighting, face, and worn accessories.
/// Floating things (thought bubbles, hearts, Zs) are drawn by `PetView` so they never get mirrored.
enum SpriteBuilder {
    static let capRows = [
        "....................ww..",
        "...................wwww.",
        "..............cccc.wwWW.",
        "............ccccccCwWW..",
        "..........cccccccCC.....",
        "........ccccccccCC......",
        "......cccccccccCCC......",
        "....cccccccccccCCCC.....",
        "..ccccccccccccccccCCC...",
        ".wwwwwwwwwwwwwwwwwwwwww.",
        ".WWWWWWWWWWWWWWWWWWWWWW.",
    ]
    static let beanieRows = [
        "..........wwww..........",
        ".........wwwwWW.........",
        ".......cccccccccc.......",
        ".....cccccccccccccC.....",
        "....cccCcccCcccCccCC....",
        "...ccCcccCcccCcccCcCC...",
        "..cccCcccCcccCcccCcccC..",
        ".wWwWwWwWwWwWwWwWwWwWwW.",
        ".WwWwWwWwWwWwWwWwWwWwWw.",
        ".WWWWWWWWWWWWWWWWWWWWWW.",
    ]
    static let flowerRows = [
        ".pp.pp.",
        "pPpppPp",
        ".pyyyp.",
        "pPpppPp",
        ".pp.pp.",
        "...g...",
        "..gg...",
        "...g...",
    ]
    static let leafRows = [
        "...o...",
        ".o.o.o.",
        ".ooooo.",
        "ooOoOoo",
        ".ooOoo.",
        "..oOo..",
        "...k...",
    ]

    static func bodyTop(_ p: PetLook) -> Int { Clawd.floorRow - Clawd.legHeight - p.lift - Clawd.bodyHeight }

    static func build(_ p: PetLook) -> PixelGrid {
        let W = Clawd.gridW, H = Clawd.gridH
        let bl = Clawd.bodyLeft, br = bl + Clawd.bodyWidth
        let u = Clawd.unit
        let bodyBottom = Clawd.floorRow - Clawd.legHeight - p.lift   // exclusive
        let top = bodyBottom - Clawd.bodyHeight

        // 1. Silhouette, facing right. 1 = body, 2 = arm. A plain rectangle with square corners.
        var body = PixelGrid(W, H)
        body.fill(bl, top, Clawd.bodyWidth, Clawd.bodyHeight, 1)
        let a = Clawd.armSize
        let armY = top + 2 * u
        let backLift = p.legPhase == 3 ? 2 : (p.legPhase == 1 ? 1 : 0)
        let frontLift = p.legPhase == 3 ? 2 : (p.legPhase == 2 ? 1 : 0)
        body.fill(bl - a, armY - backLift, a, a, 2)
        if p.umbrella {
            body.fill(br, top + u, a, a, 2)                 // raised, holding the handle
        } else if p.wave == 1 {
            body.fill(br, top, a, a, 2)                     // arm up
        } else if p.wave == 2 {
            body.fill(br, armY - u, a + 2, a, 2)            // arm out
        } else {
            body.fill(br, armY - frontLift, a, a, 2)
        }

        var legs = PixelGrid(W, H)
        for (i, offset) in Clawd.legOffsets.enumerated() {
            var x = bl + offset
            var bottom = Clawd.floorRow
            switch p.legPhase {
            case 1: if i == 0 || i == 2 { bottom -= 1 }
            case 2: if i == 1 || i == 3 { bottom -= 1 }
            case 3:
                bottom -= 1
                if i == 0 { x -= 1 } else if i == 3 { x += 1 }
            default: break
            }
            legs.fill(x, bodyBottom, Clawd.legWidth, bottom - bodyBottom, 1)
        }

        let flip = p.facing < 0
        if flip {
            body = body.mirrored()
            legs = legs.mirrored()
        }

        // 2. Colouring. Flat: one orange for the whole body, arms, and legs.
        var s = PixelGrid(W, H)
        if !Clawd.shaded {
            for y in 0..<H {
                for x in 0..<W where legs[x, y] != 0 || body[x, y] != 0 { s[x, y] = C.base }
            }
        }
        // Shaded: lighting in world space (light from the top-left, whichever way it faces).
        for y in 0..<H where Clawd.shaded {
            for x in 0..<W where legs[x, y] != 0 {
                let isTop = y == bodyBottom, isBottom = legs[x, y + 1] == 0
                let leftCol = legs[x - 1, y] == 0
                s[x, y] = isTop ? C.legDark : (isBottom ? C.leg : (leftCol ? C.shade : C.deepShade))
            }
        }
        for y in 0..<H where Clawd.shaded {
            for x in 0..<W where body[x, y] != 0 {
                let up = body[x, y - 1] == 0, down = body[x, y + 1] == 0
                let left = body[x - 1, y] == 0, right = body[x + 1, y] == 0
                if up || down || left || right {
                    s[x, y] = (down || right) ? C.outline : C.outlineLight
                    continue
                }
                if body[x, y] == 2 {
                    s[x, y] = body[x, y + 2] != 0 ? C.base : C.shade
                    continue
                }
                let rx = x - bl, ry = y - top, rr = br - 1 - x, rb = bodyBottom - 1 - y
                var c = C.base
                if rb == 1 { c = C.deepShade }
                else if rb == 2 { c = C.shade }
                else if ry == 1 { c = C.light }
                else if rx == 1 { c = C.midLight }
                else if rr == 1 { c = C.shade }
                if (ry == 2 && (rx == 2 || rx == 3)) || (ry == 3 && rx == 2) { c = C.specular }
                s[x, y] = c
            }
        }

        // 3. Face and accessories, facing right, then mirrored with the body.
        // Eyes are the mascot's signature: solid black squares, one unit in from each side, one unit down.
        var f = PixelGrid(W, H)
        let ey = top + u + p.eyeDY
        let eyeL = bl + u + p.eyeDX, eyeR = bl + 6 * u + p.eyeDX
        for ex in [eyeL, eyeR] {
            switch p.eyeStyle {
            case .normal:
                if p.eyeOpen <= 0 {
                    f.fill(ex, ey + 2, 3, 1, C.ink)                    // blink: a thin line
                } else {
                    let rows = p.eyeOpen >= 3 ? 3 : (p.eyeOpen == 2 ? 2 : 1)
                    f.fill(ex, ey + 3 - rows, 3, rows, C.ink)
                    if rows == 3 && Clawd.shaded { f[ex, ey] = C.white }
                }
            case .wide:
                f.fill(ex, ey - 1, 3, 4, C.ink)
                if Clawd.shaded { f[ex, ey - 1] = C.white }
            case .happy:
                f.stamp([".kkk.", "k...k"], at: ex - 1, ey + 1, color: C.ink)
            case .closed:
                f.stamp(["k...k", ".kkk."], at: ex - 1, ey + 1, color: C.ink)
            case .dizzy:
                f.stamp(["k.k", ".k.", "k.k"], at: ex, ey, color: C.ink)
            }
        }
        if p.blush {
            f.fill(bl + 2, ey + 4, 5, 2, C.blush)
            f.fill(bl + 17, ey + 4, 5, 2, C.blush)
        }
        // Mouths use chunky shapes, strokes as thick as the eyes are wide.
        let mx = bl + 12, my = top + 3 * u
        switch p.mouth {
        case .smile:
            f.stamp(["kk....kk",
                     "kk....kk",
                     "..kkkk..",
                     "..kkkk.."], at: mx - 4, my, color: C.ink)
        case .open:
            f.stamp(["kkkk",
                     "kkkk",
                     "kkkk",
                     "kkkk"], at: mx - 2, my, color: C.ink)
        case .chomp:
            f.stamp(["kkkkkkkk",
                     "kkkkkkkk",
                     "kkrrrrkk",
                     "kkrrrrkk"], at: mx - 4, my, colors: ["k": C.ink, "r": C.red])
        case .none: break
        }

        if p.scarf {
            let sy = bodyBottom - 5
            for x in (bl - 1)...br {
                f[x, sy] = C.red
                f[x, sy + 1] = (x - bl) % 4 == 1 ? C.white : C.red
                f[x, sy + 2] = C.darkRed
            }
            f.stamp(["rr", "rR", "rR", "ww"], at: br - 7, sy + 3, colors: ["r": C.red, "R": C.darkRed, "w": C.white])
        }

        if p.sunglasses {
            let lens = ["kkkkk", "kWkkk", "kkWkk", ".kkk."]
            let lc: [Character: UInt8] = ["k": C.ink, "W": C.lightGrey]
            f.stamp(lens, at: bl + 2, top + 3, colors: lc)
            f.stamp(lens, at: bl + 17, top + 3, colors: lc)
            f.fill(bl + 7, top + 4, 10, 1, C.ink)
            f.fill(bl, top + 4, 2, 1, C.ink)
            f.fill(bl + 22, top + 4, 2, 1, C.ink)
        }

        switch p.hat {
        case .nightcap:
            f.stamp(capRows, at: bl, top - 9, colors: ["c": C.blue, "C": C.darkBlue, "w": C.white, "W": C.lightGrey])
        case .santa:
            f.stamp(capRows, at: bl, top - 9, colors: ["c": C.red, "C": C.darkRed, "w": C.white, "W": C.lightGrey])
        case .beanie:
            f.stamp(beanieRows, at: bl, top - 7, colors: ["c": C.green, "C": C.darkGreen, "w": C.white, "W": C.lightGrey])
        case .flower:
            f.stamp(flowerRows, at: bl + 3, top - 7, colors: ["p": C.petal, "P": C.blush, "y": C.yellow, "g": C.green])
        case .leaf:
            f.stamp(leafRows, at: br - 10, top - 6, colors: ["o": C.leafOrange, "O": C.darkRed, "k": C.legDark])
        case .none:
            break
        }

        if p.umbrella {
            let cx = br                         // handle rises from the raised hand
            let y0 = top - 10
            f[cx, y0] = C.ink
            let halfWidths = [3, 5, 7, 8, 9, 9]
            for (i, hw) in halfWidths.enumerated() {
                for x in (cx - hw)...(cx + hw) {
                    let panel = ((x - (cx - 9)) / 4) % 2 == 0
                    let last = i == halfWidths.count - 1
                    f[x, y0 + 1 + i] = panel ? (last ? C.darkRed : C.red) : (last ? C.lightGrey : C.white)
                }
            }
            let hem = y0 + 1 + halfWidths.count
            for x in (cx - 9)...(cx + 9) where (x - (cx - 9)) % 4 != 3 {
                f[x, hem] = ((x - (cx - 9)) / 4) % 2 == 0 ? C.darkRed : C.lightGrey
            }
            f[cx - 3, y0 + 2] = C.petal
            f[cx - 4, y0 + 3] = C.petal
            for y in (hem + 1)...(top + u) { f[cx, y] = C.darkGrey }
        }

        if flip { f = f.mirrored() }
        s.overlay(f)
        if p.shiver != 0 { s = s.shifted(dx: p.shiver) }
        return s
    }

    /// Grid boxes around the eyes for the given look, used to detect eye pokes.
    static func eyeBoxes(_ p: PetLook) -> [(x: Int, y: Int, w: Int, h: Int)] {
        let bl = Clawd.bodyLeft
        let y = bodyTop(p) + Clawd.unit - 1 + p.eyeDY
        var boxes = [(x: bl + Clawd.unit - 1 + p.eyeDX, y: y, w: 5, h: 5),
                     (x: bl + 6 * Clawd.unit - 1 + p.eyeDX, y: y, w: 5, h: 5)]
        if p.facing < 0 { boxes = boxes.map { (x: Clawd.gridW - $0.x - $0.w, y: $0.y, w: $0.w, h: $0.h) } }
        return boxes
    }
}
