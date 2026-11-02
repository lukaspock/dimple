import AppKit
import SwiftUI
import Combine
import os

/// Shows the lock icon island and the music card on the macOS lock screen. Panels are moved into a custom
/// SkyLight space (see SkyLightBridge) on lock and torn down on unlock.
@MainActor
final class LockScreenController {
    private static let log = Logger(subsystem: "com.dimple.Dimple", category: "LockScreen")

    private let spotify: SpotifyModule?
    private let bridge = SkyLightBridge()
    private var tokens: [NSObjectProtocol] = []
    private var bag = Set<AnyCancellable>()
    private(set) var isLocked = false

    private var indicatorPanel: NotchPanel?
    private var musicPanel: NotchPanel?
    private let indicatorModel = LockIndicatorModel()
    private let musicModel = LockMusicModel()
    private var teardown: DispatchWorkItem?

    init(registry: ModuleRegistry) {
        spotify = registry.modules.compactMap { $0 as? SpotifyModule }.first
        guard bridge != nil else { Self.log.error("SkyLight unavailable: lock screen widgets disabled"); return }
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { locked ? self?.didLock() : self?.didUnlock() }
            })
        }
    }

    deinit { tokens.forEach { DistributedNotificationCenter.default().removeObserver($0) } }

    // MARK: Lock / unlock

    private func didLock() {
        NSLog("[Lock] didLock bridge=%@", bridge == nil ? "nil" : "ok"); guard !isLocked, let bridge else { return }
        isLocked = true
        teardown?.cancel()
        let geo = NotchGeometry.current()
        guard bridge.openSpace() else { Self.log.error("space setup failed: \(bridge.report)"); isLocked = false; return }

        indicatorModel.expanded = false; indicatorModel.unlocked = false
        musicModel.visible = false
        let ind = makeIndicator(geo), music = makeMusic(geo)
        indicatorPanel = ind; musicPanel = music
        for p in [ind, music].compactMap({ $0 }) { p.orderFrontRegardless(); if ProcessInfo.processInfo.environment["DIMPLE_LOCK_NOSPACE"] == nil { bridge.add(p) } }
        NSLog("[Lock] locked: %@ ind=%@ vis=%d music=%@", bridge.report, NSStringFromRect(ind.frame), ind.isVisible, music.map { NSStringFromRect($0.frame) } ?? "nil")

        DispatchQueue.main.async { self.indicatorModel.expanded = true }
        spotify?.service.refresh()
        spotify?.service.$state
            .map { $0.isRunning && $0.hasTrack && $0.isPlaying }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                self?.musicModel.visible = playing
                self?.musicPanel?.ignoresMouseEvents = !playing
            }
            .store(in: &bag)
    }

    private func didUnlock() {
        guard isLocked else { return }
        isLocked = false
        bag.removeAll()
        musicModel.visible = false
        musicPanel?.ignoresMouseEvents = true
        indicatorModel.unlocked = true                       // lock -> lock.open
        let work = DispatchWorkItem { [weak self] in
            self?.indicatorModel.expanded = false            // retract into the notch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self?.tearDown() }
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func tearDown() {
        guard !isLocked else { return }
        indicatorPanel?.orderOut(nil); musicPanel?.orderOut(nil)
        indicatorPanel = nil; musicPanel = nil
        bridge?.closeSpace()
    }

    // MARK: Panels

    private func makePanel(_ view: some View, frame: CGRect) -> NotchPanel {
        let panel = NotchPanel()
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NotchHostingView(rootView: view)
        panel.setFrame(frame, display: false)
        return panel
    }

    private func makeIndicator(_ geo: NotchGeometry) -> NotchPanel {
        let size = CGSize(width: LockIndicatorView.panelWidth(notch: geo.notchSize.width), height: geo.notchSize.height)
        let panel = makePanel(LockIndicatorView(model: indicatorModel, notchSize: geo.notchSize), frame: geo.frame(for: size))
        panel.ignoresMouseEvents = true
        return panel
    }

    private func makeMusic(_ geo: NotchGeometry) -> NotchPanel? {
        guard let spotify else { return nil }
        let size = LockScreenMusicView.size
        // Roughly 62% down the screen, above the password field.
        let y = geo.screenFrame.maxY - geo.screenFrame.height * 0.62 - size.height / 2
        let frame = CGRect(x: geo.centerX - size.width / 2, y: y, width: size.width, height: size.height)
        let panel = makePanel(LockScreenMusicView(service: spotify.service, artwork: spotify.artwork, model: musicModel), frame: frame)
        panel.ignoresMouseEvents = true
        return panel
    }
}
