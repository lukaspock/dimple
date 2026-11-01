import Foundation
import AppKit
import Combine

// MARK: - State

/// Snapshot of the system-wide "Now Playing" session (whatever Control Center shows).
struct NowPlayingState: Equatable {
    var bundleID: String?
    /// Bundle id of the hosting app for web/XPC clients (e.g. a browser playing YouTube).
    var parentBundleID: String?
    var processID: Int32?
    var title = ""
    var artist = ""
    var album = ""
    /// Seconds; 0 when unknown (live streams).
    var duration: TimeInterval = 0
    /// Playback position in seconds at `timestamp`.
    var elapsed: TimeInterval = 0
    /// Moment `elapsed` was valid.
    var timestamp = Date()
    /// 0 when paused. Defaults to 1 when playing and the source reports no rate.
    var playbackRate: Double = 0
    var playing = false
    var isMusicApp = false
    var shuffleMode: Int?       // 1 off, 2 albums, 3 tracks
    var repeatMode: Int?        // 1 off, 2 track, 3 playlist
    var artworkData: Data?
    var artwork: NSImage?

    /// True when something is registered as Now Playing (even paused).
    var hasMedia: Bool { bundleID != nil || processID != nil }

    /// The app that should be shown/credited: browser for web media, otherwise the player itself.
    var sourceBundleID: String? { parentBundleID ?? bundleID }

    /// Localized name of the source app (best effort).
    var sourceAppName: String? {
        guard let id = sourceBundleID else { return nil }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let n = app.localizedName {
            return n
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Title to display; falls back to the app name for untagged media.
    var displayTitle: String { title.isEmpty ? (sourceAppName ?? "") : title }

    /// Locally interpolated position, clamped to `0...duration`.
    func position(at date: Date = Date()) -> TimeInterval {
        let advance = (playing && playbackRate > 0) ? max(0, date.timeIntervalSince(timestamp)) * playbackRate : 0
        let p = elapsed + advance
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }

    static let empty = NowPlayingState()

    // Artwork is compared by its bytes' size only (cheap); identity is carried by `artworkData`.
    static func == (l: NowPlayingState, r: NowPlayingState) -> Bool {
        l.bundleID == r.bundleID && l.parentBundleID == r.parentBundleID && l.processID == r.processID
            && l.title == r.title && l.artist == r.artist && l.album == r.album
            && l.duration == r.duration && l.elapsed == r.elapsed && l.timestamp == r.timestamp
            && l.playbackRate == r.playbackRate && l.playing == r.playing && l.isMusicApp == r.isMusicApp
            && l.shuffleMode == r.shuffleMode && l.repeatMode == r.repeatMode
            && l.artworkData?.count == r.artworkData?.count
    }
}

enum NowPlayingCommand: Int {
    case play = 0, pause = 1, togglePlayPause = 2, stop = 3
    case next = 4, previous = 5
    case toggleShuffle = 6, toggleRepeat = 7
    case rewind15 = 12, skip15 = 13
}

// MARK: - Client

/// Wraps ungive/mediaremote-adapter (`/usr/bin/perl mediaremote-adapter.pl <framework> stream`).
/// The app never links the private MediaRemote framework: a platform-signed perl process loads the
/// adapter, so macOS 15.4+ still grants Now Playing access. See Vendor/mediaremote-adapter/REVIEW.md.
@MainActor
final class MediaRemoteClient: ObservableObject {
    /// Latest raw state, including sources in `ignoredBundleIDs`.
    @Published private(set) var state = NowPlayingState.empty
    /// True while the stream process is alive and has delivered at least one line.
    @Published private(set) var isAvailable = false

    /// Sources another module already owns (Spotify has its own richer module).
    var ignoredBundleIDs: Set<String> = ["com.spotify.client"]

    /// `state`, or nil when nothing plays or the source is ignored.
    var visibleState: NowPlayingState? {
        guard state.hasMedia, !isIgnored(state) else { return nil }
        return state
    }

    func isIgnored(_ s: NowPlayingState) -> Bool {
        [s.bundleID, s.parentBundleID].contains { $0.map(ignoredBundleIDs.contains) ?? false }
    }

    // MARK: Paths

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    /// Debug/test hook: use a script + framework outside the app bundle.
    nonisolated(unsafe) static var overridePaths: (script: URL, framework: URL)?

    private static var scriptURL: URL? {
        if let o = overridePaths { return o.script }
        let b = Bundle.main
        return b.url(forResource: "mediaremote-adapter", withExtension: "pl")
            ?? b.url(forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: "MediaRemote")
    }

    private static var frameworkURL: URL? {
        if let o = overridePaths { return o.framework }
        let b = Bundle.main
        let candidates = [
            b.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
            b.resourceURL?.appendingPathComponent("MediaRemote/MediaRemoteAdapter.framework"),
            b.resourceURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func baseArguments() -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: perl.path),
              let script = scriptURL, let fw = frameworkURL else { return nil }
        return [script.path, fw.path]
    }

    /// Minimal environment: avoids inheriting stray MEDIAREMOTEADAPTER_* / ADAPTER_TEST_MODE vars.
    private static let childEnvironment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]

    // MARK: Lifecycle / supervision

    private var process: Process?
    private var generation = 0
    private var wantsRunning = false
    private var backoff: TimeInterval = 1
    private var startedAt = Date.distantPast
    private var restartWork: Task<Void, Never>?
    private var raw: [String: Any] = [:]
    private var terminationObserver: NSObjectProtocol?

    private static let maxBackoff: TimeInterval = 30

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        backoff = 1
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        launch()
    }

    func stop() {
        wantsRunning = false
        restartWork?.cancel(); restartWork = nil
        if let o = terminationObserver { NotificationCenter.default.removeObserver(o); terminationObserver = nil }
        generation += 1
        kill(process)
        process = nil
        raw = [:]
        isAvailable = false
        state = .empty
    }

    private func kill(_ p: Process?) {
        guard let p else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
    }

    private func launch() {
        guard wantsRunning, process == nil else { return }
        guard let args = Self.baseArguments() else {
            // Adapter not bundled (or perl missing): permanently unavailable, nothing to retry.
            isAvailable = false
            return
        }
        generation += 1
        let gen = generation
        raw = [:]

        let p = Process()
        p.executableURL = Self.perl
        // Default diffing is kept on purpose: artwork (~60-500 KB base64) is only re-sent when it changes.
        // --micros gives a sub-second `timestampEpochMicros`, needed for accurate interpolation.
        p.arguments = args + ["stream", "--micros"]
        p.environment = Self.childEnvironment
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }
            let lines = buffer.append(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                for l in lines { self.handle(line: l) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.processDidExit()
            }
        }

        do {
            try p.run()
            process = p
            startedAt = Date()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            scheduleRestart()
        }
    }

    private func processDidExit() {
        kill(process)
        process = nil
        raw = [:]
        isAvailable = false
        state = .empty
        guard wantsRunning else { return }
        // A healthy long run resets the backoff; a crash loop backs off up to 30 s.
        if Date().timeIntervalSince(startedAt) > 30 { backoff = 1 }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wantsRunning else { return }
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        restartWork?.cancel()
        restartWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.restartWork = nil
            self?.launch()
        }
    }

    // MARK: Parsing

    /// Envelope: `{"type":"data","diff":Bool,"payload":{...}}`.
    /// diff == false: payload is the complete state (empty `{}` = nothing playing).
    /// diff == true:  payload holds only changed keys; a JSON null removes the key.
    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "data" else { return }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let isDiff = obj["diff"] as? Bool ?? false

        if backoff > 1, Date().timeIntervalSince(startedAt) > 5 { backoff = 1 }
        if !isAvailable { isAvailable = true }

        let previousArtworkString = raw["artworkData"] as? String
        if isDiff {
            for (k, v) in payload {
                if v is NSNull { raw.removeValue(forKey: k) } else { raw[k] = v }
            }
        } else {
            raw = payload
        }
        apply(artworkChanged: (raw["artworkData"] as? String) != previousArtworkString)
    }

    private func apply(artworkChanged: Bool) {
        var s = NowPlayingState()
        let r = raw
        s.bundleID = r["bundleIdentifier"] as? String
        s.parentBundleID = r["parentApplicationBundleIdentifier"] as? String
        s.processID = (r["processIdentifier"] as? NSNumber)?.int32Value
        s.title = (r["title"] as? String) ?? ""
        s.artist = (r["artist"] as? String) ?? ""
        s.album = (r["album"] as? String) ?? ""
        s.duration = Self.seconds(r["durationMicros"]) ?? 0
        s.elapsed = Self.seconds(r["elapsedTimeMicros"]) ?? 0
        if let t = Self.seconds(r["timestampEpochMicros"]) { s.timestamp = Date(timeIntervalSince1970: t) }
        s.playing = (r["playing"] as? Bool) ?? false
        let rate = (r["playbackRate"] as? NSNumber)?.doubleValue
        s.playbackRate = s.playing ? (rate.map { $0 > 0 ? $0 : 1 } ?? 1) : 0
        s.isMusicApp = (r["isMusicApp"] as? Bool) ?? false
        s.shuffleMode = (r["shuffleMode"] as? NSNumber)?.intValue
        s.repeatMode = (r["repeatMode"] as? NSNumber)?.intValue

        if artworkChanged {
            // Artwork often arrives late or is briefly unloaded; the adapter keeps old art for the same item.
            if let b64 = r["artworkData"] as? String, let d = Data(base64Encoded: b64) {
                s.artworkData = d
                s.artwork = NSImage(data: d)
            }
        } else {
            s.artworkData = state.artworkData
            s.artwork = state.artwork
        }
        // New item without art yet: never show the previous track's cover.
        if r["artworkData"] == nil { s.artworkData = nil; s.artwork = nil }

        if s != state || s.artworkData?.count != state.artworkData?.count { state = s }
    }

    private static func seconds(_ v: Any?) -> TimeInterval? {
        guard let n = v as? NSNumber else { return nil }
        return n.doubleValue / 1_000_000
    }

    // MARK: Control (short-lived adapter processes)

    func send(_ command: NowPlayingCommand) {
        applyOptimistic(command)
        run(["send", String(command.rawValue)])
    }

    func togglePlayPause() { send(.togglePlayPause) }
    func play() { send(.play) }
    func pause() { send(.pause) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    /// `enabled == false` -> shuffle off, true -> shuffle tracks.
    func setShuffle(_ enabled: Bool) { run(["shuffle", enabled ? "3" : "1"]) }
    /// 1 off, 2 track, 3 playlist.
    func setRepeat(mode: Int) { run(["repeat", String(mode)]) }

    func seek(to seconds: TimeInterval) {
        let t = max(0, seconds)
        state.elapsed = state.duration > 0 ? min(t, state.duration) : t
        state.timestamp = Date()
        run(["seek", String(Int64(state.elapsed * 1_000_000))])
    }

    private func applyOptimistic(_ c: NowPlayingCommand) {
        guard state.hasMedia else { return }
        let now = Date()
        switch c {
        case .togglePlayPause, .play, .pause:
            let target = c == .togglePlayPause ? !state.playing : (c == .play)
            guard target != state.playing else { return }
            state.elapsed = state.position(at: now)
            state.timestamp = now
            state.playing = target
            state.playbackRate = target ? 1 : 0
        default: break
        }
    }

    /// Runs `perl script framework <args>` once, killed after 4 s; output is discarded.
    private func run(_ extra: [String]) {
        guard let base = Self.baseArguments() else { return }
        let p = Process()
        p.executableURL = Self.perl
        p.arguments = base + extra
        p.environment = Self.childEnvironment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p.isRunning { p.terminate() } }
    }
}

/// Splits a byte stream into complete UTF-8 lines. Called from the pipe's reader queue only.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var out: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if !lineData.isEmpty, let s = String(data: lineData, encoding: .utf8) { out.append(s) }
        }
        // Guard against a runaway line without newline (corrupt output).
        if pending.count > 32 * 1024 * 1024 { pending.removeAll() }
        return out
    }
}
