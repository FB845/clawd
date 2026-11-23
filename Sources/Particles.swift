import AppKit

/// Little pixel sprites used by particles.
enum Glyph: String {
    case heart, z, note, sparkle, sparkleSmall, star, dust, crumb, drop, rain, splash, snow, steam

    private var art: ([String], [Character: UInt8]) {
        switch self {
        case .heart: return ([".hh.hh.", "hwhhhhh", "hhhhhhh", ".hhhhh.", "..hhh..", "...h..."], ["h": C.heart, "w": C.white])
        case .z: return (["zzzzz", "...z.", "..z..", ".z...", "zzzzz"], ["z": C.zzz])
        case .note: return (["..nn.", "..n.n", "..n..", "..n..", "nnn..", "nnn.."], ["n": C.blue])
        case .sparkle: return (["..y..", "..y..", "yyWyy", "..y..", "..y.."], ["y": C.yellow, "W": C.white])
        case .sparkleSmall: return ([".y.", "yWy", ".y."], ["y": C.yellow, "W": C.white])
        case .star: return (["..y..", ".yyy.", "yyyyy", ".yyy.", ".y.y."], ["y": C.gold])
        case .dust: return ([".ww.", "wwww", ".ww."], ["w": C.lightGrey])
        case .crumb: return (["cc", "ck"], ["c": C.cookie, "k": C.chocolate])
        case .drop: return ([".d.", "ddd", "dwd", ".d."], ["d": C.water, "w": C.white])
        case .rain: return (["r", "r", "r", "r"], ["r": C.water])
        case .splash: return (["r"], ["r": C.water])
        case .snow: return ([".s.", "sss", ".s."], ["s": C.snow])
        case .steam: return ([".g", "g."], ["g": C.lightGrey])
        }
    }

    var image: CGImage? { Art.image("glyph." + rawValue) { Art.grid(art.0, art.1) } }
    var isWeather: Bool { self == .rain || self == .splash || self == .snow }
}

/// One floating sprite. Positions are in screen coordinates (y up) so effects stay put in
/// the world when Clawd walks away from them.
struct Particle {
    var glyph: Glyph
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var ax: CGFloat = 0
    var ay: CGFloat = 0
    var drag: CGFloat = 0
    var life: CGFloat
    var age: CGFloat = 0
    var wobble: CGFloat = 0
    var wobbleFreq: CGFloat = 0
    var phase: CGFloat = 0
    var scale0: CGFloat = 1
    var scale1: CGFloat = 1
    var alpha: CGFloat = 1
    var fadeIn: CGFloat = 0.1
    var fadeOut: CGFloat = 0.35
    var spin: CGFloat = 0
    var angle: CGFloat = 0
    var front = true
    var floorY: CGFloat? = nil
    var settle = false
    var resting = false
}

/// A damped spring used for squash, tilt, hop, and bubble placement.
struct Spring {
    var x: CGFloat = 0
    var v: CGFloat = 0
    var target: CGFloat = 0
    var k: CGFloat
    var c: CGFloat

    /// Explicit integration only stays stable for small steps (k·dt² + 2c·dt < 4). A late frame
    /// (15 fps, or the main thread stalling) used to exceed that, so the spring rang ever harder until
    /// the squash hit its clamp and Clawd flickered between squashed and stretched. Long frames are
    /// split into small fixed sub-steps instead, and a spring that somehow went non-finite settles.
    mutating func step(_ dt: CGFloat) {
        guard dt > 0 else { return }
        let n = max(1, Int((dt / Spring.maxStep).rounded(.up)))
        let h = dt / CGFloat(n)
        for _ in 0..<n {
            let a = k * (target - x) - c * v
            v += a * h
            x += v * h
        }
        if !x.isFinite || !v.isFinite { x = target; v = 0 }
    }

    static let maxStep: CGFloat = 1.0 / 120
}
