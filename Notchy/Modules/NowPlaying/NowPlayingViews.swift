import SwiftUI

private let softSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
private let fade = Animation.easeOut(duration: 0.2)

/// Cover art, or the source app's icon when the source provides no artwork.
struct NowPlayingCover: View {
    @ObservedObject var model: NowPlayingModel
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image = model.cover {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = model.appIcon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(size * 0.04)
            } else {
                Color.white.opacity(0.08)
                    .overlay(Image(systemName: "play.circle").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.3)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(fade, value: model.cover == nil)
    }
}

struct NowPlayingCompactLeading: View {
    @ObservedObject var model: NowPlayingModel
    var body: some View { NowPlayingCover(model: model, size: 20, radius: 5) }
}

struct NowPlayingCompactTrailing: View {
    @ObservedObject var model: NowPlayingModel
    var body: some View {
        let playing = model.state?.playing ?? false
        ZStack {
            EqualizerView(isPlaying: playing, color: model.accent).opacity(playing ? 1 : 0)
            Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7)).opacity(playing ? 0 : 1)
        }
        .frame(width: 18, height: 18)
        .animation(fade, value: playing)
    }
}

private struct NPSlider: View {
    var value: Double
    var tint: Color
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
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

/// Same layout as `MediaCardContent` (360 x 142), driven by `NowPlayingModel`.
struct NowPlayingCardContent: View {
    static let size = MediaCardContent.size
    @ObservedObject var model: NowPlayingModel
    @State private var seekFraction: Double?

    var body: some View {
        if let s = model.state {
            VStack(spacing: 0) {
                header(s)
                Spacer(minLength: 0)
                progress(s)
                Spacer(minLength: 0)
                controls(s)
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        } else {
            Color.clear.frame(width: Self.size.width, height: Self.size.height)
        }
    }

    private func header(_ s: NowPlayingState) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button { model.openSource() } label: { NowPlayingCover(model: model, size: 48, radius: 10) }
                .buttonStyle(PressScale())
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle(s)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .id(s.displayTitle + "\u{1F}" + s.artist)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(fade, value: s.displayTitle)
            DotLevelView(isPlaying: s.playing, color: model.accent)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
        }
        .frame(height: 48)
    }

    private func subtitle(_ s: NowPlayingState) -> String {
        if !s.artist.isEmpty { return s.artist }
        if !s.album.isEmpty { return s.album }
        return s.sourceAppName ?? ""
    }

    private func progress(_ s: NowPlayingState) -> some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !s.playing || seekFraction != nil)) { ctx in
            let seekable = s.duration > 0
            let pos = seekFraction.map { $0 * s.duration } ?? s.position(at: ctx.date)
            HStack(spacing: 10) {
                Text(timeString(pos)).frame(width: 36, alignment: .leading)
                if seekable {
                    NPSlider(value: pos / s.duration, tint: .white.opacity(0.55),
                             onChange: { seekFraction = $0 },
                             onEnd: { f in model.seek(to: f * s.duration); seekFraction = nil })
                    Text("-" + timeString(max(s.duration - pos, 0))).frame(width: 36, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .frame(height: 16)
    }

    private func controls(_ s: NowPlayingState) -> some View {
        HStack(spacing: 0) {
            Group {
                if let mode = s.shuffleMode {
                    Button { model.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(mode > 1 ? Color.white : Color.white.opacity(0.35))
                            .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                    }
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            Spacer(minLength: 0)
            Button { model.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            Button { model.togglePlayPause() } label: {
                Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 26))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 44)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.12)))
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 6)
            Button { model.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Button { model.openSource() } label: {
                Group {
                    if let icon = model.appIcon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22).opacity(0.7)
                    } else {
                        Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(width: 44, height: 44, alignment: .trailing).contentShape(Rectangle())
            }
        }
        .buttonStyle(PressScale())
        .foregroundStyle(.white)
        .animation(softSpring, value: s.playing)
        .animation(fade, value: s.shuffleMode)
    }
}
