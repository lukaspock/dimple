import SwiftUI

@MainActor func calendarRelativeText(_ e: CalEvent, now: Date) -> String {
    if e.start <= now { return "läuft" }
    let m = e.minutesUntilStart(now)
    if m <= 0 { return "Jetzt" }
    if m < 60 { return "in \(m) min" }
    let h = m / 60, r = m % 60
    return r == 0 ? "in \(h) Std" : "in \(h) Std \(r) min"
}

@MainActor private func calTime(_ d: Date) -> String { CalendarModule.timeFormatter.string(from: d) }

struct CalendarGlyph: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar").symbolRenderingMode(.monochrome).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct CalendarTitleLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
            .lineLimit(2).multilineTextAlignment(.leading).minimumScaleFactor(0.85)
    }
}

struct CalendarCompactLeading: View {
    @ObservedObject var service: CalendarService
    var body: some View {
        Image(systemName: "calendar").symbolRenderingMode(.monochrome).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(service.events.first?.color ?? .white.opacity(0.8))
    }
}

struct CalendarCompactTrailing: View {
    @ObservedObject var service: CalendarService
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            if let e = service.events.first {
                Text(calendarRelativeText(e, now: ctx.date))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

struct CalendarExpandedView: View {
    @ObservedObject var service: CalendarService

    var body: some View {
        Group {
            switch service.access {
            case .denied: permission
            default: list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permission: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
            Button { service.openPrivacySettings() } label: {
                Text("Kalenderzugriff erlauben").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(.white))
            }.buttonStyle(.plain)
        }
    }

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let shown = Array(service.events.filter { $0.end > ctx.date }.prefix(3))
            if shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                    Text("Keine weiteren Termine heute").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(shown) { e in CalendarRow(event: e, now: ctx.date) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct CalendarRow: View {
    let event: CalEvent
    let now: Date
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(event.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("\(calTime(event.start)) – \(calTime(event.end))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            if event.joinURL != nil {
                Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            }
            Text(calendarRelativeText(event, now: now))
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 8).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hover && event.joinURL != nil ? 0.12 : 0.06)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let u = event.joinURL { NSWorkspace.shared.open(u) } }
    }
}
