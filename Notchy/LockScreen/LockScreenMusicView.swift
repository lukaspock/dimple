import SwiftUI

@MainActor
final class LockMusicModel: ObservableObject {
    @Published var visible = false
}

/// Translucent blur behind the card (real behind-window blur, rounded by a mask image).
private struct CardBlur: NSViewRepresentable {
    let radius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        let d = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        v.maskImage = mask
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Lock screen music card: the shared media layout on a translucent blurred material.
struct LockScreenMusicView: View {
    static let pad: CGFloat = 22
    static let size = CGSize(width: MediaCardContent.size.width + 2 * pad, height: MediaCardContent.size.height + 2 * pad)
    @ObservedObject var service: SpotifyService
    @ObservedObject var artwork: ArtworkLoader
    @ObservedObject var model: LockMusicModel

    var body: some View {
        MediaCardContent(service: service, artwork: artwork, allowsActivate: false)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(ZStack { CardBlur(radius: 36); Color.black.opacity(0.28) })
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            .environment(\.colorScheme, .dark)
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.visible ? 1 : 0.92)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.visible)
    }
}
