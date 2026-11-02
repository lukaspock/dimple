import Foundation
import AppKit
import Combine

/// Plain snapshot of the Spotify player.
struct SpotifyState: Equatable {
    var isRunning = false
    var isPlaying = false
    var title = ""
    var artist = ""
    var album = ""
    var artworkURL: URL?
    var duration: TimeInterval = 0
    /// Player position at `fetchedAt`.
    var position: TimeInterval = 0
    /// 0...100
    var volume: Int = 50
    var shuffling = false
    var fetchedAt = Date()

    var hasTrack: Bool { !title.isEmpty }

    /// Locally interpolated position.
    func position(at date: Date) -> TimeInterval {
        let p = isPlaying ? position + max(0, date.timeIntervalSince(fetchedAt)) : position
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

/// AppleScript bridge to Spotify (no MediaRemote). All scripts run on ONE serial queue.
@MainActor
final class SpotifyService: ObservableObject {
    nonisolated static let bundleID = "com.spotify.client"
    nonisolated private static let sep = "\u{1F}"

    @Published private(set) var state = SpotifyState()

    private let queue = DispatchQueue(label: "dimple.spotify.applescript")
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var expanded = false
    private var inFlight = false
    private var epoch = 0                 // bumped by commands so stale fetches get dropped
    private var volumeWork: Task<Void, Never>?
    private var lastVolumeWrite = Date.distantPast

    // MARK: Lifecycle

    func start() {
        guard observers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        observers.append((dnc, dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }))
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyService.bundleID else { return }
                Task { @MainActor in self?.refresh() }
            }))
        }
        refresh()
    }

    func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        timer?.invalidate(); timer = nil; timerInterval = 0
        volumeWork?.cancel()
    }

    func setExpanded(_ value: Bool) {
        expanded = value
        updateTimer()
        if value { refresh() }
    }

    // MARK: Polling

    static var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func refresh() {
        guard Self.spotifyIsRunning else {
            if state != SpotifyState() { state = SpotifyState() }
            updateTimer()
            return
        }
        guard !inFlight else { return }
        inFlight = true
        let startEpoch = epoch
        queue.async { [weak self] in
            let raw = Self.run(Self.fetchScript)
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                guard startEpoch == self.epoch else { self.scheduleRefresh(after: 0.3); return }
                guard Self.spotifyIsRunning else { self.state = SpotifyState(); self.updateTimer(); return }
                // Transient AppleScript failure (nil): keep the last known state instead of flickering to empty.
                guard let raw else { self.updateTimer(); return }
                var s = Self.parse(raw)
                s.isRunning = true
                if s != self.state { self.state = s }
                self.updateTimer()
            }
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            self?.refresh()
        }
    }

    private func updateTimer() {
        let wanted: TimeInterval = !state.isRunning ? 0 : (state.isPlaying || expanded ? 1 : 5)
        guard wanted != timerInterval || (wanted > 0 && timer == nil) else { return }
        timer?.invalidate(); timer = nil; timerInterval = wanted
        guard wanted > 0, !observers.isEmpty else { return }
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = wanted * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Commands (all no-ops when Spotify isn't running, except activate)

    func togglePlayPause() {
        state.position = state.position(at: Date()); state.fetchedAt = Date()
        state.isPlaying.toggle()
        command("playpause")
    }
    func toggleShuffle() {
        state.shuffling.toggle()
        command("set shuffling to \(state.shuffling ? "true" : "false")")
    }
    func nextTrack() { command("next track") }
    func previousTrack() { command("previous track") }

    func seek(to seconds: TimeInterval) {
        let s = max(0, state.duration > 0 ? min(seconds, state.duration) : seconds)
        state.position = s; state.fetchedAt = Date()
        command("set player position to (\(Int(s * 1000)) / 1000)")
    }

    /// Throttled: at most one write per ~80 ms, trailing value always sent.
    func setVolume(_ value: Int) {
        let v = min(max(value, 0), 100)
        state.volume = v
        volumeWork?.cancel()
        let wait = max(0, 0.08 - Date().timeIntervalSince(lastVolumeWrite))
        volumeWork = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            guard !Task.isCancelled, let self else { return }
            self.lastVolumeWrite = Date()
            self.command("set sound volume to \(v)", refreshAfter: false)
        }
    }

    /// Brings Spotify to the front (launches it if needed — explicit user action).
    func activate() {
        queue.async { _ = Self.run("tell application \"Spotify\" to activate") }
    }

    private func command(_ body: String, refreshAfter: Bool = true) {
        guard Self.spotifyIsRunning else { return }
        epoch += 1
        queue.async { _ = Self.run("tell application \"Spotify\" to \(body)") }
        if refreshAfter { scheduleRefresh(after: 0.25) }
    }

    // MARK: AppleScript

    nonisolated private static let fetchScript = """
    tell application "Spotify"
        set sep to (ASCII character 31)
        set ps to player state as text
        if ps is "stopped" then return ps
        set tn to "" 
        set ar to ""
        set al to ""
        set au to ""
        set du to "0"
        set po to "0"
        set vo to "50"
        set sh to "false"
        try
            set sh to shuffling as text
        end try
        try
            set t to current track
            try
                set tn to name of t as text
            end try
            try
                set ar to artist of t as text
            end try
            try
                set al to album of t as text
            end try
            try
                set au to artwork url of t as text
            end try
            try
                set du to duration of t as text
            end try
        end try
        try
            set po to player position as text
        end try
        try
            set vo to sound volume as text
        end try
        return ps & sep & tn & sep & ar & sep & al & sep & au & sep & du & sep & po & sep & vo & sep & sh
    end tell
    """

    /// NSAppleScript is not thread-safe: only ever call from `queue`.
    nonisolated private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }

    // MARK: Parsing

    /// Parses the delimiter separated reply. Never fails; unknown input yields an empty state.
    nonisolated static func parse(_ raw: String, now: Date = Date()) -> SpotifyState {
        var s = SpotifyState(fetchedAt: now)
        let f = raw.trimmingCharacters(in: .newlines).components(separatedBy: sep)
        guard let first = f.first else { return s }
        s.isPlaying = first.lowercased() == "playing"
        guard f.count >= 8 else { return s }
        func text(_ i: Int) -> String {
            let t = f[i].trimmingCharacters(in: .whitespaces)
            return t == "missing value" ? "" : t
        }
        s.title = text(1); s.artist = text(2); s.album = text(3)
        let art = text(4)
        s.artworkURL = art.isEmpty ? nil : URL(string: art)   // ads: empty artwork
        s.duration = (number(f[5]) ?? 0) / 1000   // ms -> s
        s.position = number(f[6]) ?? 0
        s.volume = Int((number(f[7]) ?? 50).rounded())
        if f.count >= 9 { s.shuffling = f[8].lowercased().hasPrefix("true") }
        return s
    }

    /// Locale-tolerant number parsing ("268,9039", "268.9039", "1.234,5").
    nonisolated static func number(_ raw: String) -> Double? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let comma = t.lastIndex(of: ","), let dot = t.lastIndex(of: "."), dot < comma {
            t = t.replacingOccurrences(of: ".", with: "")      // dot was a thousands separator
        }
        t = t.replacingOccurrences(of: ",", with: ".")
        if t.filter({ $0 == "." }).count > 1, let last = t.lastIndex(of: ".") {
            let head = t[..<last].replacingOccurrences(of: ".", with: "")
            t = head + t[last...]
        }
        return Double(t)
    }
}
