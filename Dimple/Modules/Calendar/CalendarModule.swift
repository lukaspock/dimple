import SwiftUI
import Combine

/// Shows upcoming calendar events: a notice ~10 min before and at the start, a countdown island in the last 5 minutes.
@MainActor
final class CalendarModule: NotchModule {
    let id = "calendar"
    let priority = 50
    let title = "Calendar"
    let iconName = "calendar"
    let compactWingWidth: CGFloat = 58
    let expandedContentSize = CGSize(width: 340, height: 140)

    let service = CalendarService()
    private let subject = PassthroughSubject<Void, Never>()
    private var bag = Set<AnyCancellable>()
    private var isExpanded = false
    private(set) var notice: NotchNotice?
    private var lastActive = false

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    /// Next event that has not started yet, or one that started less than a minute ago.
    private var imminent: CalEvent? {
        let now = Date()
        return service.events.first { $0.start.timeIntervalSince(now) > -60 }
    }

    var isActive: Bool {
        if isExpanded { return true }
        guard let e = imminent else { return false }
        return e.start.timeIntervalSinceNow <= 300
    }

    func start() {
        guard bag.isEmpty else { return }
        service.changed.sink { [weak self] in self?.update() }.store(in: &bag)
        service.start()
    }

    func stop() { service.stop(); bag.removeAll() }

    func setExpanded(_ expanded: Bool) { isExpanded = expanded }

    private func update() {
        let new = makeNotice()
        let noticeChanged = new?.id != notice?.id
        notice = new
        let active = isActive
        if noticeChanged || active != lastActive || active { 
            lastActive = active
            DispatchQueue.main.async { [subject] in subject.send() }
        }
    }

    private func makeNotice() -> NotchNotice? {
        guard let e = imminent else { return nil }
        let delta = e.start.timeIntervalSinceNow
        let time = Self.timeFormatter.string(from: e.start)
        if delta <= 0 {
            return NotchNotice(id: "cal-now-\(e.id)", duration: 5, priority: 20, wingWidth: 90,
                leading: { CalendarGlyph(text: "Jetzt", color: e.color) },
                trailing: { CalendarTitleLabel(title: e.title) })
        } else if delta <= 600 {
            return NotchNotice(id: "cal-pre-\(e.id)", duration: 5, priority: 20, wingWidth: 90,
                leading: { CalendarGlyph(text: time, color: e.color) },
                trailing: { CalendarTitleLabel(title: e.title) })
        }
        return nil
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    func makeCompactLeading() -> AnyView { AnyView(CalendarCompactLeading(service: service)) }
    func makeCompactTrailing() -> AnyView { AnyView(CalendarCompactTrailing(service: service)) }
    func makeExpandedContent() -> AnyView { AnyView(CalendarExpandedView(service: service)) }
}
