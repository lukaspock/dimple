import AppKit

/// Physical notch (or fallback pill) of the screen the island lives on.
struct NotchGeometry: Equatable {
    static let fallbackSize = CGSize(width: 190, height: 32)

    var screenFrame: CGRect
    var notchSize: CGSize
    var centerX: CGFloat
    var hasNotch: Bool

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let size = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            return NotchGeometry(screenFrame: frame, notchSize: size, centerX: (left.maxX + right.minX) / 2, hasNotch: true)
        }
        return NotchGeometry(screenFrame: frame, notchSize: fallbackSize, centerX: frame.midX, hasNotch: false)
    }

    /// Panel frame (global coordinates) for an island of `size`, flush with the top edge.
    func frame(for size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}
