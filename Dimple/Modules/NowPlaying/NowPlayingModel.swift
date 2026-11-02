import AppKit
import SwiftUI
import Combine
import os

/// Bridges `MediaRemoteClient` to the views: visible state, cover, accent colour, source app icon, commands.
@MainActor
final class NowPlayingModel: ObservableObject {
    /// Non-nil when something (not ignored) is registered as Now Playing.
    @Published private(set) var state: NowPlayingState?
    @Published private(set) var cover: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var available = false

    let client = MediaRemoteClient()
    private var bag = Set<AnyCancellable>()
    private var artKey = ""
    private var artTask: Task<Void, Never>?
    private var iconBundle: String?
    private static var iconCache: [String: NSImage] = [:]
    private let log = Logger(subsystem: "app.dimple", category: "NowPlaying")
    private var availabilityCheck: Task<Void, Never>?

    #if DEBUG
    /// DIMPLE_NOWPLAYING_DEBUG: 1 = no artwork, 2 = generated artwork + shuffle, 3 = live stream (no duration).
    private let debugMode: Int? = ProcessInfo.processInfo.environment["DIMPLE_NOWPLAYING_DEBUG"].flatMap { Int($0) }
    #endif

    var playing: Bool { state?.playing == true && !(state?.displayTitle.isEmpty ?? true) }

    func start() {
        guard bag.isEmpty else { return }
        #if DEBUG
        if let mode = debugMode { startDebug(mode); return }
        #endif
        client.$state.sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        client.$isAvailable.sink { [weak self] in self?.available = $0 }.store(in: &bag)
        client.start()
        availabilityCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, !self.client.isAvailable else { return }
            self.log.error("Now Playing adapter unavailable; module stays inactive")
        }
    }

    func stop() {
        availabilityCheck?.cancel(); artTask?.cancel()
        client.stop(); bag.removeAll()
        state = nil; cover = nil; artKey = ""
    }

    // MARK: State

    private func refresh() {
        let new = client.visibleState
        if new != state { state = new }
        updateIcon(new?.sourceBundleID)
        updateArtwork(new)
    }

    private func updateIcon(_ id: String?) {
        guard id != iconBundle else { return }
        iconBundle = id
        guard let id else { appIcon = nil; return }
        if let hit = Self.iconCache[id] { appIcon = hit; return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            Self.iconCache[id] = icon; appIcon = icon
        } else { appIcon = nil }
    }

    private func updateArtwork(_ s: NowPlayingState?) {
        let key = s.map { "\($0.sourceBundleID ?? "")|\($0.title)|\($0.artist)|\($0.artworkData?.count ?? 0)" } ?? ""
        guard key != artKey else { return }
        artKey = key
        artTask?.cancel()
        guard let img = s?.artwork ?? s?.artworkData.flatMap({ NSImage(data: $0) }) else {
            cover = nil; accent = .white; return
        }
        cover = img
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { accent = .white; return }
        let box = UncheckedBox(cg)
        artTask = Task { [weak self] in
            let c = await Task.detached(priority: .utility) { Color(nsColor: ArtworkLoader.accentColor(from: box.value)) }.value
            guard !Task.isCancelled else { return }
            self?.accent = c
        }
    }

    // MARK: Commands

    func togglePlayPause() { debugApply { $0.playing.toggle() } ?? client.togglePlayPause() }
    func next() { if !debugNoop() { client.next() } }
    func previous() { if !debugNoop() { client.previous() } }
    func toggleShuffle() {
        guard let s = state, s.shuffleMode != nil else { return }
        if debugApply({ $0.shuffleMode = $0.shuffleMode == 1 ? 3 : 1 }) != nil { return }
        client.setShuffle(s.shuffleMode == 1)
    }
    func seek(to t: TimeInterval) {
        if debugApply({ $0.elapsed = t; $0.timestamp = Date() }) != nil { return }
        client.seek(to: t)
    }

    /// Activates the source app, launching it if needed.
    func openSource() {
        guard let id = state?.sourceBundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Debug injection

    @discardableResult
    private func debugApply(_ f: (inout NowPlayingState) -> Void) -> Void? {
        #if DEBUG
        guard debugMode != nil, var s = state else { return nil }
        let now = Date()
        s.elapsed = s.position(at: now); s.timestamp = now
        f(&s)
        s.playbackRate = s.playing ? 1 : 0
        state = s
        return ()
        #else
        return nil
        #endif
    }
    private func debugNoop() -> Bool {
        #if DEBUG
        return debugMode != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    private func startDebug(_ mode: Int) {
        var s = NowPlayingState()
        s.bundleID = "com.apple.WebKit.GPU"
        s.parentBundleID = "com.google.Chrome"
        s.processID = 1
        s.title = "Lofi Hip Hop Radio - Beats to Relax/Study to"
        s.artist = "YouTube – Lofi Girl"
        s.duration = mode == 3 ? 0 : 180
        s.elapsed = 42; s.timestamp = Date(); s.playbackRate = 1; s.playing = true
        if mode == 2 {
            s.shuffleMode = 1
            s.artwork = Self.generatedArtwork()
            s.artworkData = s.artwork?.tiffRepresentation
        }
        available = true
        state = s
        updateIcon(s.sourceBundleID)
        updateArtwork(s)
    }

    private static func generatedArtwork() -> NSImage {
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.lockFocus()
        NSGradient(colors: [NSColor(hue: 0.62, saturation: 0.8, brightness: 0.9, alpha: 1),
                            NSColor(hue: 0.92, saturation: 0.85, brightness: 0.95, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 200, height: 200), angle: 55)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 60, width: 80, height: 80)).fill()
        img.unlockFocus()
        return img
    }
    #endif
}

private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
