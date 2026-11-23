import AppKit
import IOKit.ps

/// Read-only probes of what the Mac is doing. None of these need special permissions,
/// except music, which asks once for Automation access to Music / Spotify.
enum Sensors {
    static func secondsSinceKey() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    static func secondsSinceAnyInput() -> Double {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    static func battery() -> (level: Int, onAC: Bool, hasBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let listRef = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return (100, true, false) }
        let list = listRef as NSArray
        for item in list {
            let ps = item as CFTypeRef
            guard let descRef = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue(),
                  let d = descRef as NSDictionary as? [String: Any] else { continue }
            if (d[kIOPSTypeKey] as? String) != kIOPSInternalBatteryType { continue }
            let level = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (level, onAC, true)
        }
        return (100, true, false)
    }

    static func isNight() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 || hour >= 23
    }
}

/// Knows whether Music or Spotify is playing, without ever blocking the main thread.
///
/// Both players broadcast a distributed notification whenever playback changes, so Clawd listens
/// instead of asking. The old approach sent an Apple Event from the main thread every 8 seconds;
/// while a player was busy (changing tracks, buffering) that call could stall every animation.
/// A rare background poll through `osascript` fills in the state at launch and is a safety net.
final class MusicWatcher: NSObject {
    static let shared = MusicWatcher()

    /// Main thread. Called with the debounced state.
    var onChange: ((Bool) -> Void)?
    private(set) var isPlaying = false

    private static let players: [(bundle: String, name: String, note: String)] = [
        ("com.apple.Music", "Music", "com.apple.Music.playerInfo"),
        ("com.spotify.client", "Spotify", "com.spotify.client.PlaybackStateChanged"),
    ]
    private var playing: [String: Bool] = [:]       // bundle -> playing, as last reported
    private var pendingStop: DispatchWorkItem?
    private var pollTimer: Timer?
    private var running = false
    private let pollQueue = DispatchQueue(label: "clawd.music", qos: .utility)
    private var polling = false

    func start() {
        guard !running else { return }
        running = true
        let dnc = DistributedNotificationCenter.default()
        for p in MusicWatcher.players {
            // Accessory apps are never "active", so delivery must not be suspended in the background.
            dnc.addObserver(self, selector: #selector(playerChanged(_:)), name: Notification.Name(p.note),
                            object: nil, suspensionBehavior: .deliverImmediately)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appQuit(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        poll()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stop() {
        guard running else { return }
        running = false
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollTimer?.invalidate()
        pollTimer = nil
        playing = [:]
        publish(immediately: true)
    }

    @objc private func playerChanged(_ note: Notification) {
        guard running, let p = MusicWatcher.players.first(where: { $0.note == note.name.rawValue }) else { return }
        let state = (note.userInfo?["Player State"] as? String)?.lowercased()
        playing[p.bundle] = state == "playing"
        publish()
    }

    @objc private func appQuit(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundle = app.bundleIdentifier, playing[bundle] != nil else { return }
        playing[bundle] = false
        publish()
    }

    /// Asks running players for their state off the main thread. Never launches a player.
    private func poll() {
        guard running, !polling else { return }
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let targets = MusicWatcher.players.filter { runningBundles.contains($0.bundle) }
        for p in MusicWatcher.players where !runningBundles.contains(p.bundle) { playing[p.bundle] = false }
        guard !targets.isEmpty else { publish(); return }
        polling = true
        pollQueue.async { [weak self] in
            var results: [String: Bool] = [:]
            for p in targets {
                if let s = MusicWatcher.playerState(p.name) { results[p.bundle] = s == "playing" }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                guard self.running else { return }
                for (bundle, isOn) in results { self.playing[bundle] = isOn }
                self.publish()
            }
        }
    }

    /// Runs `osascript` with a hard time limit, so a busy player can only delay this background poll.
    private static func playerState(_ app: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"\(app)\" to return (player state as string)"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            task.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Starts dancing at once, but waits a moment before stopping: changing tracks often reports
    /// a brief pause, which used to make Clawd stop and restart mid-song.
    private func publish(immediately: Bool = false) {
        let now = playing.values.contains(true)
        if now {
            pendingStop?.cancel()
            pendingStop = nil
            set(true)
        } else if immediately {
            pendingStop?.cancel()
            pendingStop = nil
            set(false)
        } else if isPlaying && pendingStop == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingStop = nil
                if !self.playing.values.contains(true) { self.set(false) }
            }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func set(_ value: Bool) {
        guard value != isPlaying else { return }
        isPlaying = value
        onChange?(value)
    }
}
