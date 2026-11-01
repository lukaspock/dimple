import SwiftUI
import AppKit

/// State machine for the countdown timer / stopwatch. Source of truth for `TimerModule`; usable from anywhere:
/// `NotchyTimerService.shared.start(duration: 600)`, `.startStopwatch()`, `.pause()`, `.reset()`.
/// Time is derived from dates (no per-tick state), so views only need a TimelineView while running.
@MainActor
final class NotchyTimerService: ObservableObject {
    static let shared = NotchyTimerService()

    enum Mode { case timer, stopwatch }
    enum Phase { case idle, running, paused }

    @Published private(set) var mode: Mode = .timer
    @Published private(set) var phase: Phase = .idle
    /// Length of the current countdown (for progress and chip selection).
    @Published private(set) var total: TimeInterval = 300
    /// Timer running: end date. Stopwatch running: virtual start date.
    @Published private(set) var anchor = Date()
    /// Value while paused (remaining for timer, elapsed for stopwatch).
    @Published private(set) var frozen: TimeInterval = 0
    /// Set for a few seconds after a countdown ended (drives the "Done" notice).
    @Published private(set) var doneID: Int?

    private var doneCounter = 0
    private var fireTimer: Timer?
    private var doneClear: Task<Void, Never>?
    private var lastDuration: TimeInterval = 300

    private init() {}

    // MARK: Reading

    /// Remaining (timer) or elapsed (stopwatch) seconds at `date`.
    func value(at date: Date) -> TimeInterval {
        switch phase {
        case .idle: return mode == .timer ? lastDuration : 0
        case .paused: return frozen
        case .running: return mode == .timer ? max(anchor.timeIntervalSince(date), 0) : max(date.timeIntervalSince(anchor), 0)
        }
    }

    /// 0...1 ring/bar progress (timer: remaining share, stopwatch: seconds within the current minute).
    func progress(at date: Date) -> Double {
        let v = value(at: date)
        switch mode {
        case .timer: return total > 0 ? min(max(v / total, 0), 1) : 0
        case .stopwatch: return v.truncatingRemainder(dividingBy: 60) / 60
        }
    }

    // MARK: API

    func start(duration: TimeInterval) {
        guard duration > 0 else { return }
        lastDuration = duration
        total = duration
        mode = .timer
        anchor = Date().addingTimeInterval(duration)
        phase = .running
        scheduleFire()
    }

    func startStopwatch() {
        mode = .stopwatch
        anchor = Date()
        phase = .running
        cancelFire()
    }

    func pause() {
        guard phase == .running else { return }
        frozen = value(at: Date())
        phase = .paused
        cancelFire()
    }

    func resume() {
        guard phase == .paused else { return }
        let now = Date()
        anchor = mode == .timer ? now.addingTimeInterval(frozen) : now.addingTimeInterval(-frozen)
        phase = .running
        if mode == .timer { scheduleFire() }
    }

    func togglePause() {
        switch phase {
        case .running: pause()
        case .paused: resume()
        case .idle: mode == .timer ? start(duration: lastDuration) : startStopwatch()
        }
    }

    /// Stops everything; the island hides.
    func reset() {
        cancelFire()
        phase = .idle
        frozen = 0
    }

    /// Switches mode and starts it right away (the island is hidden while idle).
    func switchMode(to new: Mode) {
        guard new != mode || phase == .idle else { return }
        new == .timer ? start(duration: lastDuration) : startStopwatch()
    }

    /// Adds/removes time on a countdown (min 1 s remaining).
    func adjust(by delta: TimeInterval) {
        guard mode == .timer else { return }
        switch phase {
        case .running:
            let remaining = max(value(at: Date()) + delta, 1)
            anchor = Date().addingTimeInterval(remaining)
            total = max(total + delta, remaining)
            scheduleFire()
        case .paused:
            frozen = max(frozen + delta, 1)
            total = max(total + delta, frozen)
        case .idle: break
        }
    }

    // MARK: URL scheme  notchy://timer?minutes=10 | seconds=90 | mode=stopwatch | action=pause|resume|toggle|reset

    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "notchy", url.host?.lowercased() == "timer" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let a = q("action")?.lowercased() {
            switch a {
            case "pause": pause()
            case "resume": resume()
            case "toggle": togglePause()
            case "reset", "stop", "cancel": reset()
            default: return false
            }
            return true
        }
        if q("mode")?.lowercased() == "stopwatch" || q("stopwatch") != nil { startStopwatch(); return true }
        let secs = (q("minutes").flatMap(Double.init) ?? 0) * 60 + (q("seconds").flatMap(Double.init) ?? 0)
        start(duration: secs > 0 ? secs : lastDuration)
        return true
    }

    // MARK: Finish

    private func scheduleFire() {
        cancelFire()
        let t = Timer(fire: anchor, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        fireTimer = t
    }

    private func cancelFire() { fireTimer?.invalidate(); fireTimer = nil }

    private func finish() {
        guard phase == .running, mode == .timer else { return }
        cancelFire()
        phase = .idle
        frozen = 0
        doneCounter += 1
        doneID = doneCounter
        NSSound(named: "Glass")?.play()
        let id = doneCounter
        doneClear?.cancel()
        doneClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            guard !Task.isCancelled, self?.doneID == id else { return }
            self?.doneID = nil
        }
    }
}

/// Receives `notchy://` URLs via the Apple Event handler, so no AppDelegate change is needed
/// (requires the CFBundleURLTypes entry in Info.plist).
final class TimerURLHandler: NSObject {
    static let shared = TimerURLHandler()
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
                                                     forEventClass: 0x4755524C, andEventID: 0x4755524C) // 'GURL','GURL'
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue, let url = URL(string: s) else { return } // '----'
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = NotchyTimerService.shared.handle(url: url) } }
    }
}
