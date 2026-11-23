import AppKit

enum PetState {
    case idle, walk, sleep, think, pet, startle, drag, fall, land
    case chase, kick, eat, greet, bump, dizzy, squint
}

/// What Claude Code is currently doing, as reported through the control socket.
enum Companion: Equatable {
    case thinking
    case tool(String)   // bash, edit, read, web, agent, other
    case attention
    case done
}

/// Owns the floating window, the behaviour state machine, physics, perching,
/// sensors, toys, friends, mood, the Claude Code companion overlay, and input.
final class PetController: NSObject, NSMenuDelegate {
    static let winW: CGFloat = 360
    static let winH: CGFloat = 210
    static let footPad: CGFloat = winH - (PetView.origin.y + CGFloat(Clawd.floorRow) * PetView.pixel)  // 10
    static let bodyLeftOffset: CGFloat = PetView.origin.x + CGFloat(Clawd.bodyLeft) * PetView.pixel    // 144
    static let bodyWidth: CGFloat = CGFloat(Clawd.bodyWidth) * PetView.pixel                           // 72
    static let petHeight: CGFloat = CGFloat(Clawd.bodyHeight + Clawd.legHeight) * PetView.pixel        // 72
    static let gravity: CGFloat = 2600

    let window: NSWindow
    let view: PetView
    let isPrimary: Bool
    private var socket: ControlSocket?

    // Behaviour
    private(set) var state: PetState = .idle
    private var stateTime: TimeInterval = 0
    private var stateDuration: TimeInterval = 2
    private var pos: NSPoint
    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var facing = 1
    private var animAccum: TimeInterval = 0
    private var animTick = 0
    private var blinkTimer: TimeInterval = 3
    private var blinkSeq: [Int] = []
    private var eyeOpen = 3
    private var sinceInteraction: TimeInterval = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var fps = 0
    private var walkingOff = false
    private var lastLook = PetLook()

    // Perching on windows
    private var perch: Surface?
    private var surfaces: [Surface] = []
    private var surfaceAccum: TimeInterval = 0
    private var perchAccum: TimeInterval = 0
    private var perchingEnabled = UserDefaults.standard.object(forKey: "perching") as? Bool ?? true

    // Sensors
    private var sensorAccum: [String: TimeInterval] = [:]
    private var typingSamples = 0
    private var userTyping = false
    private var userAway = false
    private var musicEnabled = UserDefaults.standard.object(forKey: "music") as? Bool ?? true
    private var musicPlaying = false
    private var tired = false
    private var onAC = true
    private var batteryKnown = false
    private var night = false
    private var hour = 12
    private var season: Season = .summer
    private var weather: Weather?
    private var weatherSaid: String?
    private var yawnUntil: TimeInterval = 0
    private var yawnTimer: TimeInterval = 20
    private var thunderTimer: TimeInterval = 30
    private var clipCount = -1
    private var transientBubble: (bubble: Bubble, until: TimeInterval)?
    private var hopUntil: TimeInterval = 0

    // Toys
    private var ball: Toy?
    private var snack: Toy?
    private var chaseTarget: Toy?
    private var chaseCooldown: TimeInterval = 0
    private var kicked = false
    private var ballHitCooldown: TimeInterval = 0
    private var ballStyle = BallStyle(rawValue: UserDefaults.standard.string(forKey: "ballStyle") ?? "") ?? .classic

    // Friends
    private var peers: [Peer] = []
    private var greetCooldown: [pid_t: TimeInterval] = [:]
    private var bumpCooldown: TimeInterval = 0
    private var lastPublished = NSPoint(x: -9999, y: -9999)
    private var peerHeartbeat: TimeInterval = 0

    // Pokes
    private var petTimes: [TimeInterval] = []
    private var shakeTimes: [TimeInterval] = []
    private var lastDragX: CGFloat = 0
    private var lastDragDir = 0
    private var dizzyPending = false

    // Mood (0 sulky ... 100 delighted), remembered between launches
    private var mood: Double = 55
    private var sulky: Bool { mood <= 25 }
    private var happy: Bool { mood >= 75 }

    // Permission requests from Claude Code, answered by clicking Clawd's card
    private var approvals: [Approval] = []
    private lazy var approvalPanel: ApprovalPanel = {
        let p = ApprovalPanel()
        p.onDecision = { [weak self] allow in self?.decide(allow) }
        return p
    }()

    // Claude Code companion
    private var companion: Companion?
    private var companionSeen: TimeInterval = 0
    private var companionUntil: TimeInterval = .infinity
    private var speechUntil: TimeInterval = 0

    // Dragging
    private var pressed = false
    private var dragging = false
    private var dragOffset = NSPoint.zero
    private var dragSamples: [(t: TimeInterval, p: NSPoint)] = []

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        isPrimary = !ControlSocket.primaryIsAlive()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var x = vf.midX - PetController.winW / 2
        if !isPrimary { x += CGFloat.random(in: -260...260) }
        pos = NSPoint(x: x.rounded(), y: vf.minY - PetController.footPad)
        // The window spans the screen's width; Clawd slides inside it as a layer.
        let frame = NSRect(x: screen.frame.minX, y: pos.y, width: screen.frame.width, height: PetController.winH)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        view = PetView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true   // turned off only while the cursor is over Clawd
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.title = isPrimary ? "Clawd" : "Clawd (friend)"
        view.controller = self
        window.contentView = view
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.clampToScreen() }

        if isPrimary {
            let sock = ControlSocket { [weak self] msg in self?.handleControl(msg) }
            sock.requestHandler = { [weak self] msg, responder in self?.handleApproval(msg, responder) }
            sock.start()
            socket = sock
        }

        loadMood()
        schedule(fps: 60)

        MusicWatcher.shared.onChange = { [weak self] on in self?.musicPlaying = on }
        if musicEnabled { MusicWatcher.shared.start() }

        updateClock()
        sensorAccum["weather"] = 0   // startWeather() does the first fetch; the timer takes over after 15 min
        enter(.idle, duration: 2)
        startWeather()
    }

    func shutdown() {
        socket?.stop()
        PeerRegistry.unpublish()
        ball?.close()
        snack?.close()
        saveMood()
    }

    // MARK: - Geometry

    private var feetCenterX: CGFloat { pos.x + PetController.winW / 2 }
    private var feetY: CGFloat { pos.y + PetController.footPad }

    private var screen: NSScreen {
        let c = NSPoint(x: pos.x + PetController.winW / 2, y: pos.y + PetController.winH / 2)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private var screenFloor: CGFloat { screen.visibleFrame.minY }
    private var floorY: CGFloat { (perch?.y ?? screenFloor) - PetController.footPad }
    private var minX: CGFloat { (perch?.minX ?? screen.visibleFrame.minX) - PetController.bodyLeftOffset }
    private var maxX: CGFloat { (perch?.maxX ?? screen.visibleFrame.maxX) - PetController.bodyLeftOffset - PetController.bodyWidth }
    private var screenMinX: CGFloat { screen.visibleFrame.minX - PetController.bodyLeftOffset }
    private var screenMaxX: CGFloat { screen.visibleFrame.maxX - PetController.winW + PetController.bodyLeftOffset }

    private var airborne: Bool { state == .drag || state == .fall }

    private func clampToScreen() {
        pos.x = min(max(pos.x, screenMinX), screenMaxX)
        if !airborne {
            perch = nil
            pos.y = floorY
        }
        placeWindow()
    }

    /// Keeps the window on Clawd's screen at Clawd's height and slides the pet to its x position.
    private func placeWindow() {
        let scr = screen.frame
        let target = NSRect(x: scr.minX, y: pos.y, width: scr.width, height: PetController.winH)
        if window.frame != target { window.setFrame(target, display: false) }
        view.offsetX = pos.x - target.minX
    }

    // MARK: - Mood

    private func loadMood() {
        let d = UserDefaults.standard
        mood = d.object(forKey: "mood") as? Double ?? 55
        if isPrimary, let last = d.object(forKey: "lastSeen") as? Date {
            let days = floor(Date().timeIntervalSince(last) / 86400)
            if days >= 1 { mood = max(0, mood - min(20, days * 5)) }
        }
        saveMood()
    }

    private func saveMood() {
        guard isPrimary else { return }
        UserDefaults.standard.set(mood, forKey: "mood")
        UserDefaults.standard.set(Date(), forKey: "lastSeen")
    }

    private func adjustMood(_ delta: Double) {
        mood = min(100, max(0, mood + delta))
        saveMood()
    }

    private var moodLabel: String {
        switch mood {
        case ..<15: return "sulking"
        case ..<26: return "grumpy"
        case ..<50: return "so-so"
        case ..<75: return "content"
        case ..<90: return "happy"
        default: return "delighted"
        }
    }

    private var moodSpeed: CGFloat { happy ? 1.3 : (sulky ? 0.8 : 1.0) }

    // MARK: - State machine

    private func enter(_ s: PetState, duration: TimeInterval) {
        state = s
        stateTime = 0
        stateDuration = duration
        if s != .walk { walkingOff = false }
        switch s {
        case .startle:
            view.bounce(-12)
            view.burst(.sweat)
        case .pet:
            view.bounce(8)
            if !sulky { view.burst(.hearts) }
        case .dizzy:
            view.burst(.stars)
        case .bump:
            view.bounce(16)
            view.burst(.stars)
        case .greet:
            view.bounce(5)
        default:
            break
        }
        updateLook()
    }

    private func chooseNext() {
        switch state {
        case .idle:
            if companion != nil || !approvals.isEmpty { enter(.idle, duration: .random(in: 2...5)); return }
            if userAway { enter(.sleep, duration: 36000); return }
            let sleepy = tired || night
            let r = Double.random(in: 0..<1)
            if sinceInteraction > 45 && r < (sleepy ? 0.45 : 0.2) {
                enter(.sleep, duration: .random(in: 20...60))
            } else if r < (happy ? 0.45 : 0.38) && perchingEnabled && !tired && tryJump() {
                // airborne now
            } else if happy && r < 0.5 && walkTowardMouse() {
                // heading for the cursor
            } else if r < 0.66 {
                startWalk()
            } else if r < 0.78 {
                enter(.think, duration: .random(in: 2...4))
            } else {
                enter(.idle, duration: .random(in: 1.5...4))
            }
        case .bump:
            turn()
            vx = CGFloat(facing) * 50
            enter(.walk, duration: .random(in: 1.5...3))
        case .eat:
            chaseTarget = nil
            adjustMood(8)
            enter(.pet, duration: 1.6)
        case .kick:
            chaseTarget = nil
            chaseCooldown = uptime + .random(in: 2...5)
            enter(.idle, duration: .random(in: 1.0...2.5))
        case .chase:
            chaseTarget = nil
            chaseCooldown = uptime + 5
            enter(.idle, duration: .random(in: 1.0...3.0))
        default:
            enter(.idle, duration: .random(in: 1.0...3.5))
        }
    }

    private func startWalk() {
        facing = Bool.random() ? 1 : -1
        if pos.x < minX + 80 { facing = 1 } else if pos.x > maxX - 80 { facing = -1 }
        vx = CGFloat(facing) * .random(in: 35...60) * (tired ? 0.5 : 1) * moodSpeed
        enter(.walk, duration: .random(in: 1.5...5))
    }

    private func walkTowardMouse() -> Bool {
        let m = NSEvent.mouseLocation
        guard screen.frame.contains(m) else { return false }
        let d = m.x - feetCenterX
        guard abs(d) > 80 else { return false }
        facing = d > 0 ? 1 : -1
        let speed: CGFloat = 60 * moodSpeed
        vx = CGFloat(facing) * speed
        enter(.walk, duration: min(6, Double(abs(d) / speed)))
        return true
    }

    private func turn() {
        facing = -facing
        vx = -vx
    }

    /// Hop up onto a nearby window edge, if there is one within reach.
    private func tryJump() -> Bool {
        refreshSurfaces()
        surfaceAccum = 0
        let cx = feetCenterX, fy = feetY
        let reachable = surfaces.filter { s in
            s.y > fy + 30 && s.y < fy + 240 &&
            abs(min(max(cx, s.minX + 40), s.maxX - 40) - cx) < 170
        }
        guard let s = reachable.randomElement() else { return false }
        let tx = min(max(cx, s.minX + 40), s.maxX - 40)
        let dy = s.y - fy + 12
        vy = sqrt(2 * PetController.gravity * dy)
        let flight = vy / PetController.gravity + sqrt(2 * 12 / PetController.gravity)
        vx = (tx - cx) / flight
        view.bounce(-14)
        if abs(vx) > 5 { facing = vx > 0 ? 1 : -1 }
        perch = nil
        enter(.fall, duration: .infinity)
        return true
    }

    private func tick() {
        let now = uptime
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        stateTime += dt
        sinceInteraction += dt

        pollSensors(dt)
        surfaceAccum += dt
        if surfaceAccum >= 1.5 {
            surfaceAccum = 0
            refreshSurfaces()
        } else if perch != nil {
            perchAccum += dt
            if perchAccum >= 0.1 { perchAccum = 0; trackPerch() }
        }
        stepToys(dt)

        switch state {
        case .idle:
            if stateTime >= stateDuration { chooseNext() }
            else { maybeChase(); maybeGreet() }
        case .think, .pet, .startle, .land, .sleep, .bump, .dizzy, .squint, .greet:
            if stateTime >= stateDuration { chooseNext() }
        case .walk:
            stepWalk(dt)
        case .chase:
            stepChase(dt)
        case .kick:
            if stateTime >= 0.12 && !kicked, let b = chaseTarget, b.kind == .ball {
                kicked = true
                let m = NSEvent.mouseLocation.x
                let dir: CGFloat = abs(m - b.centerX) > 40 ? (m > b.centerX ? 1 : -1) : CGFloat(facing)
                b.vx = dir * .random(in: 450...750)
                b.vy = .random(in: 350...600)
                b.grounded = false
                adjustMood(2)
                if b.style == .baseball && b.vy > 540 && Int.random(in: 0..<3) == 0 {
                    say(["Home run!", "Going, going, gone!", "Postseason swing!"].randomElement()!, seconds: 3)
                }
                view.burst(.kickPuff)
                view.bounce(-6)
            }
            if stateTime >= stateDuration { chooseNext() }
        case .eat:
            if let s = chaseTarget, s.kind == .snack {
                let bites = min(3, Int(stateTime / 0.7))
                if bites != s.bites {
                    s.bites = bites
                    if bites > 0 {
                        view.burst(.crumbs)
                        view.bounce(4)
                    }
                    if bites >= 3 { s.close(); snack = nil }
                }
            }
            if stateTime >= stateDuration { chooseNext() }
        case .drag:
            break
        case .fall:
            stepFall(dt)
        }

        if [.idle, .walk, .think, .land, .chase].contains(state) {
            blinkTimer -= dt
            if blinkTimer <= 0 && blinkSeq.isEmpty {
                blinkSeq = [1, 0, 3]
                blinkTimer = .random(in: 2.5...6)
            }
        }

        if speechUntil > 0 && now > speechUntil { speechUntil = 0; view.speech = nil }
        if let t = transientBubble, now > t.until { transientBubble = nil }
        if companion != nil && (now > companionUntil || now - companionSeen > 900) { setCompanion(nil) }

        animAccum += dt
        if animAccum >= 1.0 / 8.0 {
            animAccum -= 1.0 / 8.0
            animTick += 1
            updateLook()
        }

        placeWindow()
        if approvalPanel.isVisible {
            approvalPanel.follow(headX: feetCenterX, headTop: feetY + PetController.petHeight + 2, screen: screen.visibleFrame)
        }
        let over = pressed || view.isOverPet(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
        updateMotionFX()
        view.step(CGFloat(dt))
        let calm = view.isCalm && [.idle, .sleep, .think].contains(state) && ball == nil && snack == nil
        schedule(fps: needsFullRate ? 60 : (calm ? 15 : 30))
    }

    /// 60 Hz while something moves quickly; 30 Hz is plenty for breathing, bubbles, and particles.
    private var needsFullRate: Bool {
        if [.drag, .fall, .chase, .kick].contains(state) || pressed { return true }
        if let b = ball, !b.isResting || b.dragging { return true }
        if let s = snack, !s.isResting || s.dragging { return true }
        return stateTime < 0.4   // landings, startles, and other fresh bounces
    }

    private func schedule(fps newFPS: Int) {
        guard newFPS != fps else { return }
        fps = newFPS
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / Double(newFPS), repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = newFPS == 60 ? 0.002 : (newFPS == 30 ? 0.005 : 0.01)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Lean, stretch, swing, and breathing for the current state; the view smooths them with springs.
    private func updateMotionFX() {
        var lean: CGFloat = 0
        var stretch: CGFloat = 0
        view.pivotAtCenter = false
        switch state {
        case .drag:
            view.pivotAtCenter = true
            lean = max(-30, min(30, dragVelocityX() * 0.025))
            stretch = -0.8
        case .fall:
            lean = max(-20, min(20, vx * 0.015))
            stretch = vy > 0 ? -0.6 : -0.3
        case .walk:
            lean = CGFloat(facing) * 2.5
        case .chase:
            lean = CGFloat(facing) * 5
        case .dizzy:
            lean = 9 * sin(CGFloat(uptime) * 5)
        case .idle:
            if companion == nil && musicPlaying { lean = 6 * sin(CGFloat(uptime) * 4) }
        default:
            break
        }
        view.tiltTarget = lean
        view.stretchTarget = stretch
        switch state {
        case .sleep: view.breath = (0.045, 3.6)
        case .idle, .think, .squint, .greet: view.breath = (0.018, 3.0)
        default: view.breath = (0, 3.0)
        }
    }

    private func dragVelocityX() -> CGFloat {
        guard let first = dragSamples.first, let last = dragSamples.last,
              uptime - last.t < 0.08, last.t - first.t > 0.01 else { return 0 }
        return (last.p.x - first.p.x) / CGFloat(last.t - first.t)
    }

    private func stepWalk(_ dt: TimeInterval) {
        pos.x += vx * dt
        if walkingOff {
            let edgeR = (perch?.maxX ?? 0) + 6, edgeL = (perch?.minX ?? 0) - 6
            if (vx > 0 && feetCenterX > edgeR) || (vx < 0 && feetCenterX < edgeL) {
                perch = nil
                vy = 0
                enter(.fall, duration: .infinity)
                return
            }
        } else if pos.x < minX || pos.x > maxX {
            pos.x = min(max(pos.x, minX), maxX)
            if perch != nil && Double.random(in: 0..<1) < 0.35 { walkingOff = true } else { turn() }
        }
        // Bump into a friend walking the same ledge.
        if uptime > bumpCooldown,
           peers.contains(where: { abs($0.y - feetY) < 24 && (feetCenterX - $0.x) * CGFloat(facing) < 0 && abs($0.x - feetCenterX) < 66 }) {
            bumpCooldown = uptime + 3
            enter(.bump, duration: 0.5)
            return
        }
        if !walkingOff && stateTime >= stateDuration { enter(.idle, duration: .random(in: 1.5...4)) }
    }

    private func stepFall(_ dt: TimeInterval) {
        let prevFeet = feetY
        vy -= PetController.gravity * dt
        pos.x += vx * dt
        pos.y += vy * dt
        if pos.x < screenMinX { pos.x = screenMinX; vx = -vx * 0.5 }
        else if pos.x > screenMaxX { pos.x = screenMaxX; vx = -vx * 0.5 }
        guard vy <= 0 else { return }

        let newFeet = feetY
        let cx = feetCenterX
        var landing: Surface?
        for s in surfaces where s.minX + 8 <= cx && cx <= s.maxX - 8 && s.y <= prevFeet + 0.5 && s.y >= newFeet {
            if landing == nil || s.y > landing!.y { landing = s }
        }
        let floor = screenFloor
        if let s = landing, s.y > floor + 1 {
            pos.y = s.y - PetController.footPad
            touchDown(on: s)
        } else if newFeet <= floor {
            pos.y = floor - PetController.footPad
            touchDown(on: nil)
        }
    }

    private func touchDown(on s: Surface?) {
        if vy < -350 {
            view.bounce(min(40, -vy / 30))
            view.burst(.dust(min(1, -vy / 1200)))
            vy = -vy * 0.35
            vx *= 0.6
            perch = nil
        } else {
            let impact = -vy
            view.bounce(max(5, impact / 30))
            if impact > 200 { view.burst(.dust(min(1, impact / 1500))) }
            vy = 0
            vx = 0
            perch = s
            if dizzyPending {
                dizzyPending = false
                adjustMood(-4)
                enter(.dizzy, duration: 3)
            } else {
                enter(.land, duration: 0.35)
            }
        }
    }

    // MARK: - Perching

    /// Follows the window Clawd is standing on: rides along when it moves, falls when it goes away.
    private func trackPerch() {
        guard let p = perch, !airborne else { return }
        guard let t = SurfaceScanner.track(p.windowID) else {
            perch = nil
            vx = 0
            vy = 0
            enter(.fall, duration: .infinity)
            return
        }
        let dx = t.minX - p.minX
        let cut = (p.maxX - p.minX) < (t.maxX - t.minX) - 1   // only part of the edge is visible
        let moved = Surface(windowID: p.windowID, y: t.y, minX: p.minX + dx, maxX: cut ? p.maxX + dx : t.maxX)
        if abs(dx) > 0.5 { pos.x += dx }
        if abs(t.y - p.y) > 0.5 { pos.y = t.y - PetController.footPad }
        perch = moved
        if abs(dx) > 0.5 || abs(t.y - p.y) > 0.5 { surfaceAccum = 1.5 }   // rescan occlusion soon
    }

    private func refreshSurfaces() {
        surfaces = perchingEnabled ? SurfaceScanner.scan(headroom: 80) : []
        guard let p = perch else { return }
        if airborne { perch = nil; return }
        let cx = feetCenterX
        if let u = surfaces.first(where: { $0.windowID == p.windowID && $0.minX - 6 <= cx && cx <= $0.maxX + 6 }) {
            let dx = u.minX - p.minX
            if abs(dx) > 0.5 && abs((u.maxX - p.maxX) - dx) < 0.5 { pos.x += dx }
            if abs(u.y - p.y) > 0.5 { pos.y = u.y - PetController.footPad }
            perch = u
        } else {
            perch = nil
            vx = 0
            vy = 0
            enter(.fall, duration: .infinity)
        }
    }

    // MARK: - Toys

    private func stepToys(_ dt: TimeInterval) {
        ball?.step(dt)
        snack?.step(dt)
        // A fast ball hitting Clawd bounces off and startles it.
        if let b = ball, !b.dragging, b.speed > 300, !airborne, uptime > ballHitCooldown {
            let body = NSRect(x: pos.x + PetController.bodyLeftOffset, y: feetY, width: PetController.bodyWidth, height: PetController.petHeight)
            if body.contains(NSPoint(x: b.centerX, y: b.centerY)) {
                ballHitCooldown = uptime + 1
                b.vx = -b.vx * 0.6
                b.vy = max(b.vy, 250)
                if state != .sleep { enter(.startle, duration: 0.7) } else { enter(.startle, duration: 0.9) }
            }
        }
    }

    private func maybeChase() {
        guard approvals.isEmpty, stateTime > 0.6, uptime > chaseCooldown else { return }
        var target: Toy?
        if let s = snack, s.isResting { target = s } else if let b = ball, b.isResting { target = b }
        guard let toy = target else { return }
        if perch != nil {
            // Hop down to get it, sometimes.
            if Double.random(in: 0..<1) < 0.02 { perch = nil; vy = 0; vx = 0; enter(.fall, duration: .infinity) }
            return
        }
        guard abs(toy.bottom - feetY) < 30 else { return }
        if sulky && toy.kind == .ball && Bool.random() { chaseCooldown = uptime + 6; return }
        chaseTarget = toy
        kicked = false
        enter(.chase, duration: 8)
    }

    private func stepChase(_ dt: TimeInterval) {
        guard let toy = chaseTarget, toy.window.isVisible, !toy.dragging,
              (toy.kind == .snack ? snack === toy : ball === toy) else {
            chaseTarget = nil
            enter(.idle, duration: .random(in: 1...2))
            return
        }
        let d = toy.centerX - feetCenterX
        let reach: CGFloat = toy.kind == .ball ? 36 : 26
        if abs(d) <= reach {
            if toy.kind == .ball { enter(.kick, duration: 0.5) } else { enter(.eat, duration: 2.5) }
            return
        }
        facing = d > 0 ? 1 : -1
        vx = CGFloat(facing) * 95 * moodSpeed
        pos.x = min(max(pos.x + vx * dt, screenMinX), screenMaxX)
        if stateTime >= stateDuration { chooseNext() }
    }

    private func spawnBall() {
        ball?.close()
        let b = Toy(kind: .ball, at: NSEvent.mouseLocation, style: ballStyle)
        b.vx = .random(in: -120...120)
        ball = b
    }

    private func spawnSnack() {
        snack?.close()
        snack = Toy(kind: .snack, at: NSEvent.mouseLocation)
    }

    // MARK: - Friends

    private func maybeGreet() {
        guard companion == nil, stateTime > 0.5, !peers.isEmpty else { return }
        let now = uptime
        guard let p = peers.first(where: { abs($0.y - feetY) < 24 && abs($0.x - feetCenterX) < 260 && (greetCooldown[$0.pid] ?? 0) < now }) else { return }
        greetCooldown[p.pid] = now + 40
        facing = p.x > feetCenterX ? 1 : -1
        adjustMood(1)
        enter(.greet, duration: 1.8)
    }

    @objc func callFriendAction(_ sender: Any?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", Bundle.main.bundlePath]
        try? proc.run()
    }

    // MARK: - Sensors

    private func every(_ key: String, _ interval: TimeInterval, _ dt: TimeInterval, _ body: () -> Void) {
        let acc = (sensorAccum[key] ?? interval) + dt
        if acc >= interval {
            sensorAccum[key] = 0
            body()
        } else {
            sensorAccum[key] = acc
        }
    }

    private func pollSensors(_ dt: TimeInterval) {
        every("peers", peers.isEmpty ? 2 : 0.5, dt) {
            peerHeartbeat -= peers.isEmpty ? 2 : 0.5
            if abs(feetCenterX - lastPublished.x) > 2 || abs(feetY - lastPublished.y) > 2 || peerHeartbeat <= 0 {
                PeerRegistry.publish(x: feetCenterX, y: feetY, facing: facing, state: "\(state)")
                lastPublished = NSPoint(x: feetCenterX, y: feetY)
                peerHeartbeat = 1.5
            }
            peers = PeerRegistry.others()
        }
        every("activity", 0.25, dt) {
            let sinceKey = Sensors.secondsSinceKey()
            typingSamples = sinceKey < 0.5 ? min(typingSamples + 1, 12) : max(typingSamples - 1, 0)
            userTyping = typingSamples >= 5
            let idle = Sensors.secondsSinceAnyInput()
            if idle > 600 && !userAway {
                userAway = true
                if !airborne && companion == nil { enter(.sleep, duration: 36000) }
            } else if idle < 2 && userAway {
                userAway = false
                if state == .sleep { enter(.startle, duration: 0.8) }
            }
        }
        every("clipboard", 0.5, dt) {
            let c = NSPasteboard.general.changeCount
            if clipCount >= 0 && c != clipCount { transientBubble = (.clip, uptime + 1.6) }
            clipCount = c
        }
        every("battery", 10, dt) {
            let b = Sensors.battery()
            guard b.hasBattery else { return }
            let wasAC = onAC
            onAC = b.onAC
            tired = b.level <= 20 && !b.onAC
            if batteryKnown && !wasAC && onAC && !airborne {
                sinceInteraction = 0
                enter(.pet, duration: 2.5)   // plugged in: happy
            }
            batteryKnown = true
        }
        every("clock", 30, dt) {
            updateClock()
        }
        every("weather", 900, dt) { refreshWeather() }
        every("mood", 600, dt) {
            if mood > 50 { adjustMood(-1) } else if mood < 50 { adjustMood(0.5) } else { saveMood() }
        }
        if morning && hour < 9 && state == .idle && companion == nil {
            yawnTimer -= dt
            if yawnTimer <= 0 { yawnTimer = .random(in: 25...60); yawnUntil = uptime + 1.3 }
        }
        if let w = weather, w.isThunder, state == .idle || state == .walk {
            thunderTimer -= dt
            if thunderTimer <= 0 { thunderTimer = .random(in: 20...60); enter(.startle, duration: 0.9) }
        }
    }

    // MARK: - Time, season, weather

    private var festive: Bool {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return c.month == 12 && (20...26).contains(c.day ?? 0)
    }
    private var morning: Bool { hour >= 6 && hour < 10 }

    private func updateClock() {
        night = Sensors.isNight()
        hour = Calendar.current.component(.hour, from: Date())
        season = Season.current(latitude: WeatherService.location?.lat)
    }

    private func startWeather() {
        if let loc = WeatherService.location, WeatherService.locationIsUserSet {
            fetchWeather(loc)
        } else {
            WeatherService.detectLocation { [weak self] loc in
                guard let self = self else { return }
                if let loc = loc {
                    WeatherService.saveLocation(loc, userSet: false)
                    self.season = Season.current(latitude: loc.lat)
                    self.fetchWeather(loc)
                } else if let saved = WeatherService.location {
                    self.fetchWeather(saved)
                } else {
                    EventLog.append("weather: no location available")
                }
            }
        }
    }

    private func fetchWeather(_ loc: WeatherService.Location) {
        WeatherService.fetch(loc) { [weak self] w in
            guard let self = self else { return }
            guard let w = w else { EventLog.append("weather: fetch failed for \(loc.name)"); return }
            EventLog.append("weather: \(w.place) \(Weather.format(w.tempC)) feels \(Weather.format(w.apparentC)) code \(w.code) \(w.summary)")
            self.weather = w
            if self.isPrimary && self.weatherSaid != w.category {
                self.weatherSaid = w.category
                self.say("\(Weather.format(w.tempC)) and \(w.summary) in \(w.place)", seconds: 8)
            }
            self.updateLook()
        }
    }

    private func refreshWeather() {
        if let loc = WeatherService.location { fetchWeather(loc) } else { startWeather() }
    }

    private var weatherMenuTitle: String {
        guard let w = weather else { return "Weather: not available" }
        return "Weather: \(Weather.format(w.tempC)), \(w.summary) in \(w.place)"
    }

    /// Dress and behave for the time of day, season, and weather.
    private func applyContext(_ look: inout PetLook) {
        let sleeping = state == .sleep
        let now = uptime

        if festive { look.hat = .santa }
        else if night { look.hat = .nightcap }
        else if let w = weather, w.isSnow || w.apparentC <= -3 { look.hat = .beanie }
        else if season == .spring { look.hat = .flower }
        else if season == .autumn { look.hat = .leaf }

        if let w = weather {
            if w.apparentC <= 8 { look.scarf = true }
            if w.apparentC <= 2 && !sleeping && !airborne && companion == nil && look.shiver == 0 {
                look.shiver = animTick % 2 == 0 ? 1 : -1
            }
            if w.apparentC >= 28 && !sleeping {
                look.sweat = true
                if w.apparentC >= 33 && look.mouth == .none { look.mouth = .open }
            }
            if w.isRain && !airborne && (look.bubble == .none || look.bubble == .zzz) { look.umbrella = true }
            if w.isFog && !sleeping && look.eyeStyle == .normal { look.eyeOpen = min(look.eyeOpen, 1) }
            if season == .summer && w.isClear && w.isDay && w.tempC >= 22 && !sleeping && look.eyeStyle == .normal {
                look.sunglasses = true
            }
            view.fx = w.isRain ? .rain : (w.isSnow ? .snow : .none)
        } else {
            view.fx = .none
        }

        if morning && state == .idle && companion == nil && look.bubble == .none && (animTick / 24) % 3 == 1 {
            look.bubble = .coffee
        }
        if now < yawnUntil && !airborne {
            look.eyeStyle = .closed
            look.mouth = .open
            look.squash = -1
            look.sunglasses = false
        }
    }

    // MARK: - Companion (Claude Code)

    func handleControl(_ msg: [String: Any]) {
        guard let event = msg["event"] as? String else { return }
        EventLog.append("\(event) \(msg["tool"] as? String ?? "") \(msg["message"] as? String ?? "")")
        let text: String? = (msg["message"] as? String).flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(140))
        }
        let now = uptime
        companionSeen = now
        switch event {
        case "thinking":
            setCompanion(.thinking)
        case "tool":
            setCompanion(.tool((msg["tool"] as? String) ?? "other"))
        case "attention":
            setCompanion(.attention)
            if let t = text, approvals.isEmpty { say(t, seconds: 10) }
        case "resolved":
            dropApprovals(session: msg["session"] as? String ?? "", key: msg["key"] as? String ?? "")
        case "done":
            dropApprovals(session: msg["session"] as? String ?? "")
            setCompanion(.done)
            view.burst(.sparkles)
            companionUntil = now + 4
            if let t = text { say(t, seconds: 6) }
        case "clear":
            dropApprovals(session: msg["session"] as? String ?? "")
            setCompanion(nil)
        case "notify":
            say(text ?? "Ping!", seconds: 8)
            hopUntil = now + 2
            wakeIfNeeded()
        case "say":
            if let t = text { say(t, seconds: 8) }
        case "pet":
            petAction(nil)
        case "sleep":
            enter(.sleep, duration: 3600)
        case "wake":
            if state == .sleep { enter(.startle, duration: 0.8) }
        case "ball":
            if let k = msg["kind"] as? String, let style = BallStyle(rawValue: k) { setBallStyle(style) }
            spawnBall()
        case "snack":
            spawnSnack()
        case "snapshot":
            if let path = msg["path"] as? String { view.snapshot(to: path) }
        default:
            break
        }
    }

    // MARK: - Permission requests

    /// A Claude Code permission request arrived; the hook is waiting on `responder` for the answer.
    private func handleApproval(_ msg: [String: Any], _ responder: Responder) {
        func str(_ k: String, _ limit: Int) -> String {
            String(((msg[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        let a = Approval(tool: str("tool", 40).isEmpty ? "this tool" : str("tool", 40),
                         detail: str("detail", 400), project: str("project", 60),
                         session: str("session", 80), key: str("key", 40), responder: responder)
        responder.onClose = { [weak self, weak a] in
            // Answered in Claude Code itself, or the hook gave up: drop the card.
            guard let self = self, let a = a else { return }
            self.approvals.removeAll { $0 === a }
            self.showNextApproval()
        }
        approvals.append(a)
        EventLog.append("approval requested: \(a.tool) \(a.detail.prefix(80))")
        if approvals.count == 1 {
            sinceInteraction = 0
            hopUntil = uptime + 1.2
            view.burst(.sweat)
        }
        showNextApproval()
    }

    private func showNextApproval() {
        guard let a = approvals.first else {
            approvalPanel.hide()
            if companion == .attention { setCompanion(.thinking) }
            return
        }
        view.speech = nil
        speechUntil = 0
        if [.sleep, .walk, .think, .chase, .kick, .eat].contains(state) {
            chaseTarget = nil
            enter(.idle, duration: 3)
        }
        setCompanion(.attention)
        approvalPanel.show(a, queued: approvals.count)
        approvalPanel.follow(headX: feetCenterX, headTop: feetY + PetController.petHeight + 2, screen: screen.visibleFrame)
    }

    /// Drops cards whose tool call was settled in Claude Code itself (or whose turn ended).
    private func dropApprovals(session: String, key: String? = nil) {
        guard !approvals.isEmpty, !session.isEmpty else { return }
        let stale = approvals.filter { $0.session == session && (key == nil || $0.key == key) }
        guard !stale.isEmpty else { return }
        for a in stale { a.responder.cancel() }
        approvals.removeAll { a in stale.contains { $0 === a } }
        EventLog.append("approval answered elsewhere: \(stale.count) card(s) dropped")
        showNextApproval()
    }

    /// Only a real click on the card reaches this; nothing on the socket can approve.
    private func decide(_ allow: Bool) {
        guard !approvals.isEmpty else { return }
        let a = approvals.removeFirst()
        a.responder.reply(["decision": allow ? "allow" : "deny"])
        EventLog.append("approval \(allow ? "allowed" : "denied"): \(a.tool)")
        sinceInteraction = 0
        if allow {
            view.burst(.sparkles)
            view.bounce(-10)
            setCompanion(.thinking)
        } else {
            setCompanion(nil)
            say("Okay, skipping that.", seconds: 2.5)
        }
        showNextApproval()
    }

    private func setCompanion(_ c: Companion?) {
        companion = c
        companionUntil = .infinity
        if c != nil { wakeIfNeeded() }
        updateLook()
    }

    private func wakeIfNeeded() {
        if [.sleep, .walk, .think].contains(state) {
            enter(.idle, duration: .random(in: 2...5))
        }
    }

    private func say(_ text: String, seconds: TimeInterval) {
        speechUntil = uptime + seconds
        view.speech = text
    }

    // MARK: - Appearance

    private func mouseGaze() -> (Int, Int) {
        let m = NSEvent.mouseLocation
        let c = NSPoint(x: pos.x + PetController.winW / 2, y: pos.y + PetController.winH / 2)
        let dx = m.x - c.x, dy = m.y - c.y
        let ex = abs(dx) > 40 ? (dx > 0 ? 1 : -1) : 0
        let ey = dy > 140 ? -1 : (dy < -30 ? 1 : 0)
        return (ex * facing, ey)
    }

    private func applyCompanion(_ c: Companion, to look: inout PetLook) {
        look.bubblePhase = animTick / 2
        switch c {
        case .thinking:
            look.eyeDX = 1
            look.eyeDY = -1
            look.bubble = .star
        case .tool(let kind):
            look.eyeDX = 1
            look.eyeDY = 1
            switch kind {
            case "bash": look.bubble = .hammer; look.squash = animTick % 4 < 2 ? 1 : 0
            case "edit": look.bubble = .pencil
            case "read": look.bubble = .glass
            case "web": look.bubble = .globe
            case "agent": look.bubble = .agent
            default: look.bubble = .dots
            }
        case .attention:
            look.eyeStyle = .wide
            look.bubble = approvals.isEmpty ? .question : .none   // the approval card does the talking
            if animTick % 4 < 2 { look.hop = 3; look.legPhase = 3 }
        case .done:
            look.eyeStyle = .happy
            look.blush = true
            look.mouth = .smile
            look.bubble = .check
            if animTick % 4 < 2 { look.hop = 3; look.legPhase = 3 }
        }
    }

    private func walkGait(_ look: inout PetLook) {
        let f = animTick % 4
        look.legPhase = f == 0 ? 1 : (f == 2 ? 2 : 0)
        look.lift = (f == 0 || f == 2) ? 1 : 0
    }

    private func updateLook() {
        var look = PetLook()
        look.facing = facing
        if !blinkSeq.isEmpty { eyeOpen = blinkSeq.removeFirst() } else { eyeOpen = 3 }
        look.eyeOpen = eyeOpen
        let (gx, gy) = mouseGaze()

        switch state {
        case .idle:
            if let c = companion {
                applyCompanion(c, to: &look)
            } else if musicPlaying {
                look.eyeStyle = .happy
                look.squash = animTick % 4 < 2 ? 1 : 0
                look.legPhase = animTick % 4 < 2 ? 1 : 2
                look.lift = 1
                look.bubble = .note
                look.bubblePhase = animTick / 2
            } else if userTyping {
                look.eyeDY = 1
                look.squash = -1
            } else if sulky {
                look.eyeDX = -gx          // pointedly looks away
                look.eyeDY = 0
                look.eyeOpen = min(look.eyeOpen, 2)
                if (animTick / 24) % 4 == 2 { look.bubble = .dots; look.bubblePhase = animTick / 2 }
            } else {
                look.eyeDX = gx
                look.eyeDY = gy
                if happy && (animTick / 24) % 5 == 3 { look.bubble = .heart; look.bubblePhase = animTick / 2 }
                if tired {
                    look.eyeOpen = min(look.eyeOpen, 2)
                    if (animTick / 24) % 3 == 0 { look.bubble = .lowbatt }
                }
            }
        case .walk:
            walkGait(&look)
            look.eyeDX = 1
            if tired || sulky { look.eyeOpen = min(look.eyeOpen, 2) }
        case .chase:
            walkGait(&look)
            look.eyeDX = 1
            look.eyeDY = 1
        case .kick:
            look.legPhase = 2
            look.squash = -1
            look.eyeDY = 1
            look.mouth = .open
        case .eat:
            look.eyeStyle = .happy
            look.mouth = animTick % 3 < 2 ? .chomp : .none
            look.eyeDY = 1
        case .greet:
            look.eyeStyle = .happy
            look.wave = animTick % 4 < 2 ? 1 : 2
            look.mouth = .smile
        case .bump:
            look.squash = 2
            look.eyeOpen = 0
            look.mouth = .open
        case .dizzy:
            look.eyeStyle = .dizzy
            look.bubble = .dizzy
        case .squint:
            look.eyeOpen = 1
            look.eyeDX = gx
        case .sleep:
            look.eyeStyle = .closed
            look.bubble = .zzz
            look.bubblePhase = animTick / 2
        case .think:
            look.eyeDX = 1
            look.eyeDY = -1
            look.bubble = .star
            look.bubblePhase = animTick / 2
        case .pet:
            if sulky {
                look.eyeOpen = 2
                look.eyeDX = gx
                look.squash = animTick % 4 < 2 ? 0 : 1
            } else {
                look.eyeStyle = .happy
                look.blush = true
                look.mouth = .smile
                look.bubble = .heart
                look.bubblePhase = animTick / 2
                look.squash = animTick % 4 < 2 ? 0 : 1
            }
        case .startle:
            look.eyeStyle = .wide
            look.mouth = .open
            look.bubble = .exclaim
        case .drag:
            look.eyeStyle = .wide
            look.legPhase = 3
            if stateTime < 0.7 {
                look.bubble = .exclaim
                look.mouth = .open
            } else if stateTime > 3 {
                // Held too long: flailing.
                look.legPhase = animTick % 2 == 0 ? 1 : 2
                look.mouth = .open
                look.bubble = .exclaim
                look.shiver = animTick % 2 == 0 ? 1 : -1
            } else {
                look.eyeDX = gx
                look.eyeDY = gy
            }
        case .fall:
            look.eyeStyle = .wide
            look.legPhase = 3
            look.squash = -1
        case .land:
            look.squash = stateTime < 0.18 ? 2 : 1
            look.eyeOpen = min(eyeOpen, 2)
        }

        applyContext(&look)
        if let t = transientBubble { look.bubble = t.bubble }
        if uptime < hopUntil && !airborne && animTick % 4 < 2 {
            look.hop = 3
            look.legPhase = 3
        }

        lastLook = look
        view.setLook(look)
        view.showShadow = !airborne
    }

    // MARK: - Input

    func mouseDown(_ e: NSEvent) {
        pressed = true
        dragging = false
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - pos.x, y: m.y - pos.y)
        dragSamples = [(uptime, m)]
        lastDragX = m.x
        lastDragDir = 0
        shakeTimes = []
    }

    func mouseDragged(_ e: NSEvent) {
        guard pressed else { return }
        let m = NSEvent.mouseLocation
        if !dragging {
            let d = hypot(m.x - (pos.x + dragOffset.x), m.y - (pos.y + dragOffset.y))
            if d < 4 { return }
            dragging = true
            sinceInteraction = 0
            vx = 0; vy = 0
            perch = nil
            chaseTarget = nil
            enter(.drag, duration: .infinity)
        }
        pos = NSPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y)
        placeWindow()
        let now = uptime
        dragSamples.append((now, m))
        dragSamples.removeAll { now - $0.t > 0.12 }

        // Shaking back and forth makes it dizzy.
        let dx = m.x - lastDragX
        if abs(dx) > 10 {
            let dir = dx > 0 ? 1 : -1
            if lastDragDir != 0 && dir != lastDragDir { shakeTimes.append(now) }
            lastDragDir = dir
            lastDragX = m.x
        }
        shakeTimes.removeAll { now - $0 > 1.2 }
        if shakeTimes.count >= 5 { dizzyPending = true }
    }

    func mouseUp(_ e: NSEvent) {
        guard pressed else { return }
        pressed = false
        sinceInteraction = 0
        if dragging {
            dragging = false
            refreshSurfaces()
            surfaceAccum = 0
            vx = 0; vy = 0
            if let first = dragSamples.first, let last = dragSamples.last, last.t - first.t > 0.01 {
                let t = CGFloat(last.t - first.t)
                vx = (last.p.x - first.p.x) / t
                vy = (last.p.y - first.p.y) / t
                let speed = hypot(vx, vy), maxSpeed: CGFloat = 1800
                if speed > maxSpeed { vx *= maxSpeed / speed; vy *= maxSpeed / speed }
                if abs(vx) < 60 { vx = 0 }
                if speed > 1400 { adjustMood(-1) }
            }
            if abs(vx) > 60 { facing = vx > 0 ? 1 : -1 }
            let cx = feetCenterX, fy = feetY
            if abs(vy) < 200, abs(vx) < 200, !dizzyPending,
               let s = surfaces.first(where: { $0.minX + 8 <= cx && cx <= $0.maxX - 8 && abs($0.y - fy) < 18 }) {
                perch = s
                pos.y = s.y - PetController.footPad
                vx = 0; vy = 0
                enter(.land, duration: 0.3)
            } else {
                perch = nil
                enter(.fall, duration: .infinity)
            }
            return
        }

        if state == .sleep { enter(.startle, duration: 0.8); return }
        if airborne { return }

        // A click on the eyes is a poke.
        let local = view.convert(e.locationInWindow, from: nil)
        let (px, py) = view.gridPoint(local)
        if SpriteBuilder.eyeBoxes(lastLook).contains(where: { px >= $0.x && px < $0.x + $0.w && py >= $0.y && py < $0.y + $0.h }) {
            adjustMood(-2)
            enter(.squint, duration: 1.3)
            return
        }

        // Petting; too much of it at once is dizzying.
        let now = uptime
        petTimes.append(now)
        petTimes.removeAll { now - $0 > 4 }
        adjustMood(3)
        if petTimes.count >= 6 {
            petTimes = []
            enter(.dizzy, duration: 2.5)
        } else {
            enter(.pet, duration: sulky ? 1.0 : 1.8)
        }
    }

    // MARK: - Menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ sel: Selector, tag: Int = 0, key: String = "") {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        func info(_ title: String, tag: Int) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            item.isEnabled = false
            menu.addItem(item)
        }
        add("Pet Clawd", #selector(petAction(_:)))
        add("Go to sleep", #selector(sleepAction(_:)), tag: 1)
        add("Come here", #selector(comeHereAction(_:)))
        menu.addItem(.separator())
        add("Throw a ball", #selector(ballAction(_:)), tag: 5)
        let picker = NSMenuItem(title: "Ball", action: nil, keyEquivalent: "")
        picker.tag = 9
        let sub = NSMenu()
        for style in BallStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(pickBall(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            if let img = Icons.ball(style) {
                item.image = NSImage(cgImage: img, size: NSSize(width: 12, height: 12))
            }
            sub.addItem(item)
        }
        picker.submenu = sub
        menu.addItem(picker)
        add("Drop a snack", #selector(snackAction(_:)), tag: 7)
        add("Call a friend", #selector(callFriendAction(_:)))
        menu.addItem(.separator())
        add("Sit on windows", #selector(togglePerching(_:)), tag: 2)
        add("Dance to music", #selector(toggleMusic(_:)), tag: 3)
        menu.addItem(.separator())
        info("Mood: \(moodLabel)", tag: 6)
        info(weatherMenuTitle, tag: 4)
        add("Set location…", #selector(setLocationAction(_:)))
        add("Refresh weather", #selector(refreshWeatherAction(_:)))
        menu.addItem(.separator())
        add(isPrimary ? "Quit Clawd" : "Send this friend home", #selector(quitAction(_:)), key: "q")
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.title = state == .sleep ? "Wake up" : "Go to sleep"
        menu.item(withTag: 2)?.state = perchingEnabled ? .on : .off
        menu.item(withTag: 3)?.state = musicEnabled ? .on : .off
        menu.item(withTag: 4)?.title = weatherMenuTitle
        menu.item(withTag: 5)?.title = ball == nil ? "Throw a ball" : "Take the ball away"
        for item in menu.item(withTag: 9)?.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == ballStyle.rawValue ? .on : .off
        }
        menu.item(withTag: 6)?.title = "Mood: \(moodLabel) (\(Int(mood)))"
        menu.item(withTag: 7)?.title = snack == nil ? "Drop a snack" : "Take the snack away"
    }

    func showMenu(_ e: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: e, for: view)
    }

    @objc func pickBall(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = BallStyle(rawValue: raw) else { return }
        setBallStyle(style)
        if ball == nil { spawnBall() }
    }

    /// Remembers the choice and swaps the ball that's already out, if any.
    private func setBallStyle(_ style: BallStyle) {
        ballStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "ballStyle")
        ball?.style = style
    }

    @objc func ballAction(_ sender: Any?) {
        if let b = ball {
            b.close()
            ball = nil
            if state == .chase || state == .kick { chaseTarget = nil; enter(.idle, duration: 1) }
        } else {
            spawnBall()
        }
    }

    @objc func snackAction(_ sender: Any?) {
        if let s = snack {
            s.close()
            snack = nil
            if state == .chase || state == .eat { chaseTarget = nil; enter(.idle, duration: 1) }
        } else {
            spawnSnack()
        }
    }

    @objc func petAction(_ sender: Any?) {
        sinceInteraction = 0
        adjustMood(3)
        if !airborne { enter(.pet, duration: 1.8) }
    }

    @objc func sleepAction(_ sender: Any?) {
        sinceInteraction = 0
        if state == .sleep { enter(.startle, duration: 0.8) } else { enter(.sleep, duration: 3600) }
    }

    @objc func comeHereAction(_ sender: Any?) {
        sinceInteraction = 0
        let m = NSEvent.mouseLocation
        perch = nil
        chaseTarget = nil
        pos = NSPoint(x: m.x - PetController.winW / 2, y: m.y + 40)
        pos.x = min(max(pos.x, screenMinX), screenMaxX)
        pos.y = min(pos.y, screen.visibleFrame.maxY - PetController.winH)
        vx = 0; vy = 0
        placeWindow()
        enter(.fall, duration: .infinity)
    }

    @objc func togglePerching(_ sender: Any?) {
        perchingEnabled.toggle()
        UserDefaults.standard.set(perchingEnabled, forKey: "perching")
        if !perchingEnabled && perch != nil && state != .drag { perch = nil; enter(.fall, duration: .infinity) }
    }

    @objc func toggleMusic(_ sender: Any?) {
        musicEnabled.toggle()
        UserDefaults.standard.set(musicEnabled, forKey: "music")
        if musicEnabled { MusicWatcher.shared.start() } else { MusicWatcher.shared.stop() }
    }

    @objc func refreshWeatherAction(_ sender: Any?) {
        weatherSaid = nil
        refreshWeather()
    }

    @objc func setLocationAction(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Where is Clawd?"
        alert.informativeText = "Type a city so Clawd can dress for the weather. Leave it empty to detect the city automatically."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. London"
        field.stringValue = WeatherService.locationIsUserSet ? (WeatherService.location?.name ?? "") : ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        weatherSaid = nil
        if query.isEmpty {
            WeatherService.saveLocation(nil, userSet: false)
            startWeather()
            return
        }
        WeatherService.geocode(query) { [weak self] loc in
            guard let self = self else { return }
            if let loc = loc {
                WeatherService.saveLocation(loc, userSet: true)
                self.season = Season.current(latitude: loc.lat)
                self.fetchWeather(loc)
            } else {
                self.say("Couldn't find \(query)", seconds: 5)
            }
        }
    }

    @objc func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
