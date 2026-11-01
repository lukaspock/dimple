import SwiftUI
import EventKit
import Combine

/// One calendar event reduced to what the notch needs.
struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let joinURL: URL?

    func minutesUntilStart(_ now: Date) -> Int { Int((start.timeIntervalSince(now) / 60).rounded(.up)) }
}

enum CalAccess: Equatable { case unknown, granted, denied }

/// Reads today's events via EventKit. No heavy polling: reacts to EKEventStoreChanged and a light timer.
@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var access: CalAccess = .unknown

    let changed = PassthroughSubject<Void, Never>()
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    #if DEBUG
    private let debugMode: Int = Int(ProcessInfo.processInfo.environment["NOTCHY_CALENDAR_DEBUG"] ?? "") ?? 0
    #else
    private let debugMode = 0
    #endif

    func start() {
        guard timer == nil else { return }
        if debugMode > 0 {
            access = .granted
        } else {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            updateAccess()
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                store.requestFullAccessToEvents { [weak self] _, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateAccess(); self?.refresh() } }
                }
            }
        }
        refresh()
        // Light tick: relative texts and notice thresholds need minute-level accuracy only.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateAccess() {
        let new: CalAccess
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: new = .granted
        case .notDetermined: new = .unknown
        default: new = .denied
        }
        if new != access { access = new }
    }

    func refresh() {
        let now = Date()
        let list: [CalEvent]
        if debugMode > 0 { list = debugEvents(now) } else {
            updateAccess()
            list = access == .granted ? fetch(now) : []
        }
        if list != events { events = list }
        changed.send()
    }

    private func fetch(_ now: Date) -> [CalEvent] {
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        guard now < end else { return [] }
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { e in
                CalEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                         title: (e.title?.isEmpty == false ? e.title! : "Ohne Titel"),
                         start: e.startDate, end: e.endDate,
                         color: Color(cgColor: e.calendar?.cgColor ?? NSColor.systemBlue.cgColor),
                         joinURL: Self.videoURL(in: [e.location, e.notes, e.url?.absoluteString]))
            }
    }

    static func videoURL(in texts: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for t in texts.compactMap({ $0 }) {
            let r = NSRange(t.startIndex..., in: t)
            for m in det.matches(in: t, range: r) {
                if let u = m.url, u.scheme?.lowercased() == "https", let h = u.host?.lowercased(), hosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return u }
            }
        }
        return nil
    }

    #if DEBUG
    private func debugEvents(_ now: Date) -> [CalEvent] {
        let first: TimeInterval = debugMode == 2 ? 4 * 60 - 10 : 8 * 60
        func ev(_ t: String, _ off: TimeInterval, _ len: TimeInterval, _ c: Color, _ url: String? = nil) -> CalEvent {
            CalEvent(id: t, title: t, start: now.addingTimeInterval(off), end: now.addingTimeInterval(off + len), color: c, joinURL: url.flatMap(URL.init))
        }
        return [ev("Design Review", first, 30 * 60, .blue, "https://zoom.us/j/123456"),
                ev("Mittagessen mit Anna", 45 * 60, 60 * 60, .green),
                ev("Sprint Planung", 135 * 60, 45 * 60, .orange, "https://meet.google.com/abc-defg-hij")]
    }
    #else
    private func debugEvents(_ now: Date) -> [CalEvent] { [] }
    #endif
}
