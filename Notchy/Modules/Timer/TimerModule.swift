import SwiftUI
import Combine

/// Countdown timer + stopwatch. Active only while running/paused; "Done" notice when a countdown ends.
@MainActor
final class TimerModule: NotchModule {
    static let shared = TimerModule()

    let id = "timer"
    let priority = 60
    let title = "Timer"
    let iconName = "timer"
    let compactWingWidth: CGFloat = 54
    let expandedContentSize = CGSize(width: 320, height: 130)

    let service = NotchyTimerService.shared
    private let subject = PassthroughSubject<Void, Never>()
    private var bag = Set<AnyCancellable>()

    init() {}

    var isActive: Bool { service.phase != .idle }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    var notice: NotchNotice? {
        guard let n = service.doneID else { return nil }
        return NotchNotice(id: "timer-done-\(n)", duration: 5, priority: 20, wingWidth: 56,
            leading: { Image(systemName: "bell.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(TimerStyle.accent) },
            trailing: { Text("Done").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) })
    }

    // MARK: Hooks (menu bar, shortcuts)

    /// Starts a countdown, e.g. from a menu bar item.
    func startPreset(minutes: Int) { service.start(duration: TimeInterval(minutes) * 60) }
    func startStopwatch() { service.startStopwatch() }

    // MARK: NotchModule

    func start() {
        guard bag.isEmpty else { return }
        TimerURLHandler.shared.install()
        // Only coarse changes notify the registry (never per tick).
        service.$phase.removeDuplicates().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        service.$mode.removeDuplicates().dropFirst().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        service.$doneID.removeDuplicates().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCHY_TIMER_DEBUG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [service] in service.start(duration: 15) }
        }
        #endif
    }

    func stop() { bag.removeAll() }
    func setExpanded(_ expanded: Bool) {}

    func makeCompactLeading() -> AnyView { AnyView(TimerCompactLeading(service: service)) }
    func makeCompactTrailing() -> AnyView { AnyView(TimerCompactTrailing(service: service)) }
    func makeExpandedContent() -> AnyView { AnyView(TimerExpandedView(service: service)) }

    private func notify() {
        DispatchQueue.main.async { [subject] in subject.send() }
    }
}
