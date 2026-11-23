import AppKit

/// Draws a pixel-art CGImage into a y-down (flipped) context the right way up.
func drawPixelImage(_ ctx: CGContext, _ img: CGImage, _ rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

func easeOutBack(_ t: CGFloat) -> CGFloat {
    let c1: CGFloat = 1.70158, c3 = c1 + 1, u = t - 1
    return 1 + c3 * u * u * u + c1 * u * u
}

func easeOut(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }

/// Cache of pixel-art images built from `PixelGrid`s.
enum Art {
    private static var cache: [String: CGImage] = [:]

    static func image(_ key: String, _ make: () -> PixelGrid) -> CGImage? {
        if let c = cache[key] { return c }
        guard let img = make().cgImage() else { return nil }
        cache[key] = img
        return img
    }

    static func grid(_ rows: [String], _ colors: [Character: UInt8]) -> PixelGrid {
        var g = PixelGrid(rows.map { $0.count }.max() ?? 0, rows.count)
        g.stamp(rows, at: 0, 0, colors: colors)
        return g
    }
}

/// Icons shown in Clawd's thought bubble, plus the toys.
enum Icons {
    static var spark: CGImage? {
        Art.image("spark") {
            Art.grid([
                ".....o.....",
                ".o...o...o.",
                "..o..o..o..",
                "...o.o.o...",
                "....OOO....",
                "ooooOOOoooo",
                "....OOO....",
                "...o.o.o...",
                "..o..o..o..",
                ".o...o...o.",
                ".....o.....",
            ], ["o": C.base, "O": C.shade])
        }
    }

    /// Claude Code's thinking spinner: · ✢ ✳ ✶ ✻ ✽, played forwards then backwards.
    static let thinkingSequence = [0, 1, 2, 3, 4, 5, 4, 3, 2, 1]

    static func thinking(_ frame: Int) -> CGImage? {
        Art.image("thinking\(frame)") { thinkingGrid(frame) }
    }

    /// Hand-drawn 11x11 versions of the six spinner glyphs.
    private static let thinkingFrames: [[String]] = [
        [   // ·
            "...........",
            "...........",
            "...........",
            "...........",
            "....ooo....",
            "....oOo....",
            "....ooo....",
            "...........",
            "...........",
            "...........",
            "...........",
        ],
        [   // ✢
            "....ooo....",
            "...ooooo...",
            "...ooooo...",
            ".oo.ooo.oo.",
            "oooo.o.oooo",
            "oooooOooooo",
            "oooo.o.oooo",
            ".oo.ooo.oo.",
            "...ooooo...",
            "...ooooo...",
            "....ooo....",
        ],
        [   // ✳
            ".....o.....",
            ".o...o...o.",
            "..o..o..o..",
            "...o.o.o...",
            "....ooo....",
            "oooooOooooo",
            "....ooo....",
            "...o.o.o...",
            "..o..o..o..",
            ".o...o...o.",
            ".....o.....",
        ],
        [   // ✶
            ".....o.....",
            ".....o.....",
            ".oo.ooo.oo.",
            "..ooooooo..",
            "...ooooo...",
            "...ooOoo...",
            "...ooooo...",
            "..ooooooo..",
            ".oo.ooo.oo.",
            ".....o.....",
            ".....o.....",
        ],
        [   // ✻
            "....ooo....",
            ".oo..o..oo.",
            ".oo..o..oo.",
            "...o.o.o...",
            "o...ooo...o",
            "oooooOooooo",
            "o...ooo...o",
            "...o.o.o...",
            ".oo..o..oo.",
            ".oo..o..oo.",
            "....ooo....",
        ],
        [   // ✽
            "....ooo....",
            ".oo.ooo.oo.",
            ".ooo.o.ooo.",
            "..oo.o.oo..",
            "oo..ooo..oo",
            "oooooOooooo",
            "oo..ooo..oo",
            "..oo.o.oo..",
            ".ooo.o.ooo.",
            ".oo.ooo.oo.",
            "....ooo....",
        ],
    ]

    private static func thinkingGrid(_ frame: Int) -> PixelGrid {
        Art.grid(thinkingFrames[max(0, min(frame, thinkingFrames.count - 1))], ["o": C.base, "O": C.shade])
    }

    static var hammer: CGImage? {
        Art.image("hammer") {
            Art.grid([
                "..HHHHHHH..",
                ".HHHHHHHHh.",
                ".hhhhhhhhh.",
                "....ss.....",
                "....sS.....",
                "....sS.....",
                "....sS.....",
                "....sS.....",
                "....SS.....",
            ], ["H": C.lightGrey, "h": C.darkGrey, "s": C.lightWood, "S": C.cookie])
        }
    }

    static var pencil: CGImage? {
        Art.image("pencil") {
            var g = PixelGrid(11, 11)
            for y in 0..<11 {
                for x in 0..<11 {
                    let d = x + y, t = x - y
                    guard d >= 9 && d <= 11 else { continue }
                    var c: UInt8
                    if t >= 7 { c = C.petal }
                    else if t >= 5 { c = C.lightGrey }
                    else if t >= -4 { c = d == 11 ? C.darkGold : C.yellow }
                    else if t >= -7 {
                        if d != 10 && t <= -6 { continue }
                        c = C.lightWood
                    } else {
                        if d != 10 { continue }
                        c = C.ink
                    }
                    g[x, y] = c
                }
            }
            return g
        }
    }

    static var glass: CGImage? {
        Art.image("glass") {
            var g = PixelGrid(11, 11)
            for y in 0..<11 {
                for x in 0..<11 {
                    let d = hypot(Double(x) - 4, Double(y) - 4)
                    if d <= 2.6 { g[x, y] = C.water } else if d <= 4.1 { g[x, y] = C.darkGrey }
                }
            }
            g[3, 3] = C.white
            g[2, 3] = C.white
            for i in 0..<4 {
                g[7 + i, 7 + i] = C.cookie
                g[8 + i, 7 + i] = C.chocolate
            }
            return g
        }
    }

    static func globe(_ frame: Int) -> CGImage? {
        Art.image("globe\(frame)") {
            let land = [
                "......xx........",
                "....xxxx....xx..",
                "...xxxxx...xxxx.",
                "..xxxxx....xxx..",
                "...xxx......x...",
                "....xx.....xxx..",
                ".....x....xxxxx.",
                "..........xxxx..",
                "...xx......xx...",
                "..xxxx..........",
                "...xx...........",
            ].map { Array($0) }
            var g = PixelGrid(11, 11)
            for y in 0..<11 {
                for x in 0..<11 {
                    let d = hypot(Double(x) - 5, Double(y) - 5)
                    guard d <= 5.2 else { continue }
                    if d > 4.4 { g[x, y] = C.darkBlue; continue }
                    g[x, y] = land[y][(x + frame) % 16] == "x" ? C.green : C.blue
                }
            }
            g[3, 2] = C.lightBlue
            g[2, 3] = C.lightBlue
            return g
        }
    }

    static var agent: CGImage? {
        Art.image("agent") {
            Art.grid([
                ".OOOOOOOOO.",
                ".OkOOOOOkO.",
                "ooooooooooo",
                ".ooooooooo.",
                ".sssssssss.",
                "..l.l.l.l..",
            ], ["O": C.light, "o": C.base, "k": C.ink, "s": C.shade, "l": C.legDark])
        }
    }

    static var question: CGImage? {
        Art.image("question") {
            Art.grid([
                ".kkkkk.",
                "kk...kk",
                ".....kk",
                "...kkk.",
                "...kk..",
                "...kk..",
                ".......",
                "...kk..",
                "...kk..",
            ], ["k": C.blue])
        }
    }

    static var check: CGImage? {
        Art.image("check") {
            Art.grid([
                ".........gg",
                "........ggG",
                ".......ggG.",
                "gg....ggG..",
                "Ggg..ggG...",
                ".GggggG....",
                "..GggG.....",
                "...GG......",
            ], ["g": C.green, "G": C.darkGreen])
        }
    }

    static var clip: CGImage? {
        Art.image("clip") {
            Art.grid([
                "...ggg...",
                "ttgGGGgtt",
                "tpppppppt",
                "tpkkkkppt",
                "tpppppppt",
                "tpkkkkkpt",
                "tpppppppt",
                "tpkkkpppt",
                "tpppppppt",
                "tTTTTTTTt",
                ".ttttttt.",
            ], ["t": C.tan, "T": C.cookie, "g": C.darkGrey, "G": C.lightGrey, "p": C.paper, "k": C.grey])
        }
    }

    static var coffee: CGImage? {
        Art.image("coffee") {
            Art.grid([
                "kkkkkkkk..",
                "kcccccck..",
                "kLooooSkkk",
                "kLooooSk.k",
                "kLooooSkkk",
                "kSSSSSSk..",
                ".kkkkkk...",
            ], ["k": C.outline, "c": C.chocolate, "L": C.light, "o": C.base, "S": C.shade])
        }
    }

    static func battery(_ lit: Bool) -> CGImage? {
        Art.image("battery\(lit)") {
            Art.grid([
                "kkkkkkkkkk..",
                "kwwwwwwwwk..",
                "kwrrwwwwwkk.",
                "kwrrwwwwwkk.",
                "kwwwwwwwwk..",
                "kkkkkkkkkk..",
            ], ["k": C.darkGrey, "w": C.panelShade, "r": lit ? C.red : C.panelShade])
        }
    }

    static var exclaim: CGImage? {
        Art.image("exclaim") {
            Art.grid([
                ".www.",
                "wrrrw",
                "wrrrw",
                "wrrrw",
                ".wrw.",
                ".wrw.",
                "..w..",
                ".www.",
                "wrrrw",
                ".www.",
            ], ["w": C.white, "r": C.red])
        }
    }

    /// Thought-bubble frame: white panel, dark outline, stepped corners, soft bottom edge.
    static var bubble: CGImage? {
        Art.image("bubble") {
            let w = 17, h = 15
            var g = PixelGrid(w, h)
            for y in 0..<h {
                for x in 0..<w {
                    let edgeX = x == 0 || x == w - 1, edgeY = y == 0 || y == h - 1
                    if edgeX && edgeY { continue }
                    let innerCorner = (x == 1 || x == w - 2) && (y == 1 || y == h - 2)
                    if edgeX || edgeY || innerCorner { g[x, y] = C.bubbleInk }
                    else if y == h - 2 { g[x, y] = C.panelShade }
                    else { g[x, y] = C.white }
                }
            }
            return g
        }
    }

    static var dotBig: CGImage? {
        Art.image("dotBig") { Art.grid([".kk.", "kwwk", "kwwk", ".kk."], ["k": C.bubbleInk, "w": C.white]) }
    }

    static var dotSmall: CGImage? {
        Art.image("dotSmall") { Art.grid([".k.", "kwk", ".k."], ["k": C.bubbleInk, "w": C.white]) }
    }

    // MARK: Toys (12 x 12)

    static func ball(_ style: BallStyle) -> CGImage? {
        switch style {
        case .classic: return classicBall
        case .baseball: return Art.image("ball.baseball") { seamBall(fill: C.white, shade: C.lightGrey, rim: C.grey, seam: C.red) }
        case .tennis: return Art.image("ball.tennis") { seamBall(fill: C.tennis, shade: C.tennisShade, rim: C.tennisShade, seam: C.white) }
        case .basketball: return Art.image("ball.basketball") { basketball() }
        case .soccer: return Art.image("ball.soccer") { soccerBall() }
        }
    }

    /// Round 12x12 ball: rim, body, and a shaded lower-right edge. `paint` can override pixels.
    private static func roundBall(fill: UInt8, shade: UInt8, rim: UInt8,
                                  paint: (_ x: Int, _ y: Int, _ dx: CGFloat, _ dy: CGFloat) -> UInt8? = { _, _, _, _ in nil }) -> PixelGrid {
        var g = PixelGrid(12, 12)
        for y in 0..<12 {
            for x in 0..<12 {
                let dx = CGFloat(x) - 5.5, dy = CGFloat(y) - 5.5
                let d = hypot(dx, dy)
                guard d <= 5.9 else { continue }
                if d > 5.0 { g[x, y] = rim; continue }
                g[x, y] = paint(x, y, dx, dy) ?? (dx + dy > 4.2 ? shade : fill)
            }
        }
        return g
    }

    /// Baseball and tennis ball: two curved seams bulging toward the middle.
    private static func seamBall(fill: UInt8, shade: UInt8, rim: UInt8, seam: UInt8) -> PixelGrid {
        var g = roundBall(fill: fill, shade: shade, rim: rim) { x, y, _, _ in
            let fx = CGFloat(x), fy = CGFloat(y)
            // Two arcs that bow in toward the middle, like ⚾.
            let left = abs(hypot(fx + 0.6, fy - 5.5) - 4.3)
            let right = abs(hypot(fx - 11.6, fy - 5.5) - 4.3)
            return min(left, right) < 0.6 ? seam : nil
        }
        g[3, 2] = C.white
        g[2, 3] = fill == C.white ? C.white : C.snow
        return g
    }

    private static func basketball() -> PixelGrid {
        roundBall(fill: C.hoops, shade: C.hoopsShade, rim: C.outline) { x, y, dx, dy in
            let fx = CGFloat(x), fy = CGFloat(y)
            if x == 6 || y == 5 { return C.outline }                       // cross lines
            let left = abs(hypot(fx + 1.0, fy - 5.5) - 4.6)                // curved side lines
            let right = abs(hypot(fx - 12.0, fy - 5.5) - 4.6)
            if min(left, right) < 0.55 { return C.outline }
            _ = (dx, dy)
            if x == 3 && y == 3 { return C.light }
            return nil
        }
    }

    private static func soccerBall() -> PixelGrid {
        var g = roundBall(fill: C.white, shade: C.lightGrey, rim: C.darkGrey)
        // Black centre patch and partial patches around the rim.
        for (x, y) in [(5, 4), (6, 4), (4, 5), (5, 5), (6, 5), (7, 5), (4, 6), (5, 6), (6, 6), (7, 6), (5, 7), (6, 7)] {
            g[x, y] = C.ink
        }
        for (x, y) in [(5, 1), (6, 1), (1, 4), (1, 5), (10, 4), (10, 5), (2, 9), (3, 9), (3, 10), (8, 9), (9, 9), (8, 10)] {
            g[x, y] = C.ink
        }
        for (x, y) in [(5, 2), (6, 2), (5, 3), (2, 5), (3, 5), (8, 5), (9, 5), (4, 8), (7, 8)] {
            g[x, y] = C.grey   // seams joining the patches
        }
        g[3, 2] = C.lightGrey
        return g
    }

    private static var classicBall: CGImage? {
        Art.image("ball") {
            var g = PixelGrid(12, 12)
            for y in 0..<12 {
                for x in 0..<12 {
                    let dx = CGFloat(x) - 5.5, dy = CGFloat(y) - 5.5
                    let d = hypot(dx, dy)
                    guard d <= 5.9 else { continue }
                    if d > 5.0 { g[x, y] = C.darkRed }
                    else if abs(dy) < 1.1 { g[x, y] = d > 4.2 ? C.lightGrey : C.white }
                    else if dx + dy > 4.2 { g[x, y] = C.darkRed }
                    else { g[x, y] = C.red }
                }
            }
            g[3, 2] = C.white
            g[2, 3] = C.petal
            g[4, 2] = C.petal
            return g
        }
    }

    static func cookie(_ bites: Int) -> CGImage? {
        Art.image("cookie\(bites)") {
            var g = PixelGrid(12, 12)
            for y in 0..<12 {
                for x in 0..<12 {
                    let dx = CGFloat(x) - 5.5, dy = CGFloat(y) - 5.5
                    let d = hypot(dx, dy)
                    guard d <= 5.9 else { continue }
                    if d > 5.0 { g[x, y] = C.cookieRim }
                    else if dx + dy < -4 { g[x, y] = C.lightWood }
                    else if dx + dy > 5 { g[x, y] = C.cookieRim }
                    else { g[x, y] = C.cookie }
                }
            }
            for (x, y) in [(3, 4), (7, 3), (5, 7), (8, 7), (3, 8), (6, 5)] { g[x, y] = C.chocolate }
            let biteCenters: [(CGFloat, CGFloat)] = [(11.5, 3.5), (11.5, 8.5), (8.5, 12.0)]
            var bitten = [Bool](repeating: false, count: 144)
            for b in 0..<min(bites, biteCenters.count) {
                let (bx, by) = biteCenters[b]
                for y in 0..<12 {
                    for x in 0..<12 where hypot(CGFloat(x) - bx, CGFloat(y) - by) <= 3.2 {
                        g[x, y] = 0
                        bitten[y * 12 + x] = true
                    }
                }
            }
            // Darken the freshly bitten edge.
            for y in 0..<12 {
                for x in 0..<12 where g[x, y] != 0 {
                    let near = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                        let nx = x + dx, ny = y + dy
                        return nx >= 0 && ny >= 0 && nx < 12 && ny < 12 && bitten[ny * 12 + nx]
                    }
                    if near { g[x, y] = C.cookieRim }
                }
            }
            return g
        }
    }
}
