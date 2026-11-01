import AppKit
import SwiftUI

/// Downloads cover art (cached by URL, stale loads cancelled) and derives a vibrant accent color.
@MainActor
final class ArtworkLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var imageURL: URL?

    private var cache: [URL: (NSImage, Color)] = [:]
    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        task?.cancel()
        guard let url else { image = nil; imageURL = nil; accent = .white; return }
        if let hit = cache[url] { apply(url, hit.0, hit.1); return }
        task = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { Self.decode(data) }.value
            guard !Task.isCancelled, let (img, color) = result, let self else { return }
            if self.cache.count > 24 { self.cache.removeAll() }
            self.cache[url] = (img, color)
            self.apply(url, img, color)
        }
    }

    func cancel() { task?.cancel() }

    private func apply(_ url: URL, _ img: NSImage, _ color: Color) {
        image = img; accent = color; imageURL = url
    }

    nonisolated private static func decode(_ data: Data) -> (NSImage, Color)? {
        guard let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (img, Color(nsColor: accentColor(from: cg)))
    }

    /// Dominant hue (weighted by saturation and brightness) from a tiny bitmap, boosted to read well on black.
    nonisolated static func accentColor(from cg: CGImage) -> NSColor {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return NSColor(white: 0.9, alpha: 1) }

        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sx = [Double](repeating: 0, count: bins), sy = sx, sSat = sx, sBri = sx
        var total = 0.0
        for i in 0..<(n * n) {
            let c = NSColor(srgbRed: CGFloat(px[i*4]) / 255, green: CGFloat(px[i*4+1]) / 255, blue: CGFloat(px[i*4+2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard b > 0.18, s > 0.12 else { continue }
            let w = Double(s * (0.25 + b))
            let bin = min(bins - 1, Int(h * CGFloat(bins)))
            weight[bin] += w; total += w
            sx[bin] += w * cos(Double(h) * 2 * .pi); sy[bin] += w * sin(Double(h) * 2 * .pi)
            sSat[bin] += w * Double(s); sBri[bin] += w * Double(b)
        }
        guard total > 0.6, let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else {
            return NSColor(white: 0.9, alpha: 1)   // grayscale cover
        }
        var hue = atan2(sy[best], sx[best]) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let sat = min(max(sSat[best] / weight[best] * 1.15, 0.55), 0.95)
        let bri = min(max(sBri[best] / weight[best] * 1.25, 0.85), 1.0)
        return NSColor(hue: CGFloat(hue), saturation: CGFloat(sat), brightness: CGFloat(bri), alpha: 1)
    }
}
