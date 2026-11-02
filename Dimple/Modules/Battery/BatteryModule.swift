import SwiftUI
import Combine

/// Battery events as transient notices: plugged in, unplugged, low (20 / 10 %), fully charged.
/// Inactive (island hidden) except while a notice is current, so hovering then reaches the expanded view.
@MainActor
final class BatteryModule: NotchModule, ObservableObject {
    let id = "battery"
    let priority = 20
    let title = "Battery"
    let iconName = "battery.100"
    let compactWingWidth: CGFloat = 58
    let expandedContentSize = CGSize(width: 300, height: 110)

    @Published private(set) var info = BatteryInfo()
    private(set) var notice: NotchNotice?
    var isActive: Bool { notice != nil }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()
    private let service = BatteryService()
    private var previous: BatteryInfo?
    private var counter = 0
    private var low20 = false, low10 = false
    private var clearTask: Task<Void, Never>?
    private var debugTimer: Timer?

    func start() {
        service.onChange = { [weak self] new in MainActor.assumeIsolated { self?.handle(new) } }
        service.start()
        if let now = service.read() { info = now; previous = now }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DIMPLE_BATTERY_DEBUG"] == "1" { startDebug() }
        #endif
    }

    func stop() { service.stop(); debugTimer?.invalidate(); clearTask?.cancel() }
    func setExpanded(_ expanded: Bool) {}

    // MARK: Event logic

    private enum Kind { case plugged, unplugged, low(Int), full }

    private func handle(_ new: BatteryInfo?) {
        guard let new else { return }
        let old = previous
        previous = new
        info = new
        if new.onAC { low20 = false; low10 = false }
        else if new.percent > 20 { low20 = false; low10 = false }
        else if new.percent > 10 { low10 = false }

        if let old, old.onAC != new.onAC { post(new.onAC ? .plugged : .unplugged) }
        else if !new.onAC, new.percent <= 10, !low10 { low10 = true; low20 = true; post(.low(10)) }
        else if !new.onAC, new.percent <= 20, !low20 { low20 = true; post(.low(20)) }
        else if let old, new.onAC, new.isCharged, !old.isCharged { post(.full) }
        else { subject.send() }   // refresh the expanded view
    }

    func tint(for i: BatteryInfo) -> Color {
        if !i.onAC && i.percent <= 20 { return .red }
        return i.onAC ? .green : .white
    }

    private func post(_ kind: Kind) {
        counter += 1
        let i = info
        let (name, duration, prio): (String, TimeInterval, Int)
        switch kind {
        case .plugged: (name, duration, prio) = ("plugged", 3, 10)
        case .unplugged: (name, duration, prio) = ("unplugged", 2.5, 10)
        case .low(let level): (name, duration, prio) = ("low\(level)", 5, 30)
        case .full: (name, duration, prio) = ("full", 3, 10)
        }
        let tint: Color
        switch kind {
        case .low: tint = .red
        case .unplugged: tint = .white
        default: tint = .green
        }
        let bolt: Bool = { if case .plugged = kind { return true } else { return false } }()
        let full: Bool = { if case .full = kind { return true } else { return false } }()
        notice = NotchNotice(id: "\(name)-\(counter)", duration: duration, priority: prio, wingWidth: compactWingWidth,
            leading: { BatteryGlyph(percent: i.percent, tint: tint, showBolt: bolt) },
            trailing: {
                Group {
                    if full { Image(systemName: "checkmark").foregroundStyle(.green) }
                    else { Text("\(i.percent)%").foregroundStyle(tint == .white ? .white : tint) }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            })
        subject.send()
        // Withdraw shortly after the core dismissed it so the module goes inactive again.
        let id = notice?.id
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.3) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.notice?.id == id else { return }
            self.notice = nil
            self.subject.send()
        }
    }

    // MARK: Views

    func statusLine(for i: BatteryInfo) -> String {
        func hm(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }
        if i.onAC {
            if i.isCharged || i.percent >= 100 { return "Fully charged" }
            if i.isCharging { return i.minutesToFull.map { "Charging – \(hm($0)) until full" } ?? "Charging" }
            return "Plugged in, not charging"
        }
        return i.minutesToEmpty.map { "On battery – \(hm($0)) left" } ?? "On battery"
    }

    // Compact content while active mirrors the current notice so the hand-over after dismissal is seamless.
    func makeCompactLeading() -> AnyView { notice?.makeLeading() ?? AnyView(EmptyView()) }
    func makeCompactTrailing() -> AnyView { notice?.makeTrailing() ?? AnyView(EmptyView()) }
    func makeExpandedContent() -> AnyView { AnyView(BatteryExpandedView(module: self)) }

    // MARK: Debug

    #if DEBUG
    private func startDebug() {
        var step = 0
        debugTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let steps: [(BatteryInfo, Kind)] = [
                    (BatteryInfo(percent: 82, onAC: true, isCharging: true, minutesToFull: 72), .plugged),
                    (BatteryInfo(percent: 82, onAC: false, minutesToEmpty: 260), .unplugged),
                    (BatteryInfo(percent: 20, onAC: false, minutesToEmpty: 40), .low(20)),
                    (BatteryInfo(percent: 10, onAC: false, minutesToEmpty: 20), .low(10)),
                    (BatteryInfo(percent: 100, onAC: true, isCharged: true), .full),
                ]
                let (i, k) = steps[step % steps.count]; step += 1
                self.info = i; self.post(k)
            }
        }
        debugTimer?.fire()
    }
    #endif
}
