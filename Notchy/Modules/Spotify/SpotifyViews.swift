import SwiftUI

private let softSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
private let fade = Animation.easeOut(duration: 0.2)

// MARK: - Shared pieces

struct CoverView: View {
    @ObservedObject var artwork: ArtworkLoader
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image = artwork.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .id(artwork.imageURL)
                    .transition(.opacity)
            } else {
                Color.white.opacity(0.08)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(.white.opacity(0.25)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(fade, value: artwork.imageURL)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(softSpring, value: configuration.isPressed)
    }
}

/// Capsule slider: tap or drag, no knob, thickens on hover/drag. Reports 0...1.
private struct CapsuleSlider: View {
    var value: Double
    var track: Color = .white.opacity(0.18)
    var tint: Color
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
            .frame(height: hovering || dragging ? 8 : 6)
            .frame(maxHeight: .infinity)
            .animation(softSpring, value: hovering || dragging)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = true; onChange(fraction($0.location.x, geo.size.width)) }
                .onEnded { dragging = false; onEnd(fraction($0.location.x, geo.size.width)) })
        }
        .frame(height: 16)
    }

    private func fraction(_ x: CGFloat, _ w: CGFloat) -> Double { w > 0 ? Double(min(max(x / w, 0), 1)) : 0 }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(max(t, 0).rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Equalizer

struct EqualizerView: View {
    var isPlaying: Bool
    var color: Color
    private let phases: [Double] = [0, 1.9, 3.7, 5.1]
    private let speeds: [Double] = [5.2, 7.1, 6.0, 8.3]

    @State private var level: Double = 0.0        // 0 = settled low, 1 = full motion
    @State private var from: Double = 0
    @State private var changedAt = Date.distantPast
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let target = isPlaying ? 1.0 : 0.0
            let k = min(1, ctx.date.timeIntervalSince(changedAt) / 0.45)
            let lvl = from + (target - from) * (1 - pow(1 - k, 3))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = (sin(t * speeds[i] + phases[i]) + sin(t * speeds[i] * 0.53 + phases[i] * 2) + 2) / 4   // 0...1
                    Capsule().fill(color)
                        .frame(width: 2.5, height: 3 + (2 + 11 * wave) * lvl)
                }
            }
            .frame(height: 16)
        }
        .onChange(of: isPlaying) { _, playing in
            from = playing ? 0 : 1   // approximate; settles within 0.45 s either way
            changedAt = Date(); active = true
            Task { try? await Task.sleep(nanoseconds: 600_000_000); active = isPlayingNow }
        }
        .onAppear { from = isPlaying ? 1 : 0; changedAt = .distantPast; active = isPlaying }
    }

    private var isPlayingNow: Bool { isPlaying }
}

// MARK: - Compact

struct SpotifyCompactLeading: View {
    @ObservedObject var service: SpotifyService
    @ObservedObject var artwork: ArtworkLoader
    var body: some View { CoverView(artwork: artwork, size: 20, radius: 5) }
}

struct SpotifyCompactTrailing: View {
    @ObservedObject var service: SpotifyService
    @ObservedObject var artwork: ArtworkLoader
    var body: some View {
        let playing = service.state.isPlaying
        ZStack {
            EqualizerView(isPlaying: playing, color: artwork.accent).opacity(playing ? 1 : 0)
            Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7)).opacity(playing ? 0 : 1)
        }
        .frame(width: 18, height: 18)
        .animation(fade, value: playing)
    }
}

// MARK: - Dotted level indicator

struct DotLevelView: View {
    var isPlaying: Bool
    var color: Color
    private let count = 14
    @State private var level: Double = 0
    @State private var from: Double = 0
    @State private var changedAt = Date.distantPast
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let target = isPlaying ? 1.0 : 0.0
            let k = min(1, ctx.date.timeIntervalSince(changedAt) / 0.5)
            let lvl = from + (target - from) * (1 - pow(1 - k, 3))
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    let x = Double(i)
                    let wave = (sin(t * 3.1 + x * 0.9) + sin(t * 4.7 - x * 0.55) + 2) / 4   // 0...1
                    let h = 2.5 + 3.5 * wave * lvl
                    Capsule().fill(color.opacity(0.55 + 0.45 * wave * lvl))
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(height: 12)
        }
        .onChange(of: isPlaying) { _, playing in
            from = playing ? 0 : 1
            changedAt = Date(); active = true
            Task { try? await Task.sleep(nanoseconds: 700_000_000); active = isPlaying }
        }
        .onAppear { from = isPlaying ? 1 : 0; changedAt = .distantPast; active = isPlaying }
    }
}

// MARK: - Shared media layout (island + lock screen)

/// Cover + title/artist + level dots, progress row, transport row. 360 x 142.
struct MediaCardContent: View {
    static let size = CGSize(width: 360, height: 142)
    @ObservedObject var service: SpotifyService
    @ObservedObject var artwork: ArtworkLoader
    @State private var seekFraction: Double?

    var body: some View {
        let s = service.state
        VStack(spacing: 0) {
            header(s)
            Spacer(minLength: 0)
            progress(s)
            Spacer(minLength: 0)
            controls(s)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
    }

    private func header(_ s: SpotifyState) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button { service.activate() } label: { CoverView(artwork: artwork, size: 48, radius: 10) }
                .buttonStyle(PressScale())
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(s.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .id(s.title + "\u{1F}" + s.artist)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(fade, value: s.title)
            DotLevelView(isPlaying: s.isPlaying, color: artwork.accent)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
        }
        .frame(height: 48)
    }

    private func progress(_ s: SpotifyState) -> some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !s.isPlaying || seekFraction != nil)) { ctx in
            let pos = seekFraction.map { $0 * s.duration } ?? s.position(at: ctx.date)
            let frac = s.duration > 0 ? pos / s.duration : 0
            HStack(spacing: 10) {
                Text(timeString(pos)).frame(width: 36, alignment: .leading)
                CapsuleSlider(value: frac, tint: .white.opacity(0.55),
                              onChange: { seekFraction = $0 },
                              onEnd: { f in service.seek(to: f * s.duration); seekFraction = nil })
                Text("-" + timeString(max(s.duration - pos, 0))).frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .frame(height: 16)
    }

    private func controls(_ s: SpotifyState) -> some View {
        HStack(spacing: 0) {
            Button { service.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(s.shuffling ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Button { service.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            Button { service.togglePlayPause() } label: {
                Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 44)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.12)))
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 6)
            Button { service.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Button { service.activate() } label: {
                Image(systemName: "laptopcomputer").font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 44, height: 44, alignment: .trailing).contentShape(Rectangle())
            }
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.white)
        .animation(softSpring, value: s.isPlaying)
        .animation(fade, value: s.shuffling)
    }
}

// MARK: - Expanded

struct SpotifyExpandedView: View {
    @ObservedObject var service: SpotifyService
    @ObservedObject var artwork: ArtworkLoader
    var body: some View { MediaCardContent(service: service, artwork: artwork) }
}
