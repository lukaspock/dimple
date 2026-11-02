import SwiftUI

/// The island silhouette, drawn top-centered in the (fixed-size) panel. Width, height and bottom radius are
/// animatable, so one spring morphs the whole shape. Flat top merges with the notch; small concave ears at the
/// top corners fade in as the island grows past the notch width.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var notchWidth: CGFloat
    var earRadius: CGFloat = 6

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), bottomRadius) }
        set { width = newValue.first.first; height = newValue.first.second; bottomRadius = newValue.second }
    }

    func path(in bounds: CGRect) -> Path {
        let r = CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: height)
        let b = max(0, min(bottomRadius, r.height / 2, r.width / 2))
        let grow = min(max((width - notchWidth) / 16, 0), 1)
        let e = min(earRadius * grow, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX - e, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX + e, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + e), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.maxX - b, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - b), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.minX - e, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}
