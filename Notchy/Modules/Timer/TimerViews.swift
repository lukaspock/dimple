import SwiftUI

enum TimerStyle {
    static let accent = Color.orange
    static let soft = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let fade = Animation.easeOut(duration: 0.2)

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(t, 0).rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
    /// Stopwatch counts up, so it rounds down.
    static func formatUp(_ t: TimeInterval) -> String { format(t.rounded(.down)) }
}

@MainActor private func text(_ s: NotchyTimerService, _ d: Date) -> String {
    s.mode == .timer ? TimerStyle.format(s.value(at: d)) : TimerStyle.formatUp(s.value(at: d))
}

// MARK: - Compact

struct TimerRing: View {
    let progress: Double
    var lineWidth: CGFloat = 2
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(progress, 0.001))
                .stroke(TimerStyle.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct TimerCompactLeading: View {
    @ObservedObject var service: NotchyTimerService
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: service.phase != .running)) { ctx in
            TimerRing(progress: service.progress(at: ctx.date))
                .frame(width: 15, height: 15)
                .opacity(service.phase == .paused ? 0.5 : 1)
        }
        .animation(TimerStyle.fade, value: service.phase)
    }
}

struct TimerCompactTrailing: View {
    @ObservedObject var service: NotchyTimerService
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: service.phase != .running)) { ctx in
            Text(text(service, ctx.date))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(TimerStyle.accent)
                .opacity(service.phase == .paused ? 0.55 : 1)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .animation(TimerStyle.fade, value: service.phase)
    }
}

// MARK: - Expanded

struct TimerExpandedView: View {
    @ObservedObject var service: NotchyTimerService
    @State private var resetTick = 0
    private let presets = [1, 5, 10, 25]

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Spacer(minLength: 0)
            timeDisplay
            Spacer(minLength: 0)
            bottomRow
        }
        .foregroundStyle(.white)
        .frame(width: 320, height: 130, alignment: .top)
        .animation(TimerStyle.soft, value: service.phase)
        .animation(TimerStyle.soft, value: service.mode)
    }

    // Toggle + stepper
    private var topRow: some View {
        HStack {
            SegmentedToggle(selection: Binding(get: { service.mode }, set: { service.switchMode(to: $0) }))
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                stepButton("minus") { service.adjust(by: -60) }
                stepButton("plus") { service.adjust(by: 60) }
            }
            .opacity(service.mode == .timer ? 1 : 0.0)
            .allowsHitTesting(service.mode == .timer)
        }
        .frame(height: 24)
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    private var timeDisplay: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: service.phase != .running)) { ctx in
            VStack(spacing: 7) {
                Text(text(service, ctx.date))
                    .font(.system(size: 40, weight: .light).monospacedDigit())
                    .foregroundStyle(service.phase == .paused ? Color.white.opacity(0.55) : .white)
                    .frame(maxWidth: .infinity)
                ProgressCapsule(value: service.progress(at: ctx.date), tint: TimerStyle.accent)
                    .opacity(service.phase == .paused ? 0.5 : 1)
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.self) { m in
                let selected = service.mode == .timer && service.phase != .idle && service.total == TimeInterval(m * 60)
                Button { service.start(duration: TimeInterval(m) * 60) } label: {
                    Text("\(m)m")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? TimerStyle.accent : .white.opacity(0.7))
                        .frame(width: 34, height: 26)
                        .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0.09)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
            }
            Spacer(minLength: 0)
            Button { resetTick += 1; service.reset() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.bounce, value: resetTick)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 32, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            Button { service.togglePause() } label: {
                Image(systemName: service.phase == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 28)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.14)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
        }
        .frame(height: 28)
    }
}

/// Thin capsule progress, no interaction.
private struct ProgressCapsule: View {
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(tint).frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// Minimal sliding segmented control: Timer | Stopwatch.
private struct SegmentedToggle: View {
    @Binding var selection: NotchyTimerService.Mode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            segment("Timer", .timer)
            segment("Stopwatch", .stopwatch)
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func segment(_ title: String, _ mode: NotchyTimerService.Mode) -> some View {
        let on = selection == mode
        return Button { withAnimation(TimerStyle.soft) { selection = mode } } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.5))
                .padding(.horizontal, 10).frame(height: 20)
                .background {
                    if on { Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "sel", in: ns) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
