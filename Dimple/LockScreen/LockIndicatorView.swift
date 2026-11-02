import SwiftUI

@MainActor
final class LockIndicatorModel: ObservableObject {
    @Published var expanded = false   // island grows out of the notch
    @Published var unlocked = false   // icon switches lock -> lock.open
}

/// Black island pill merged with the notch with a small lock icon in the right wing.
struct LockIndicatorView: View {
    static let wing: CGFloat = 36
    static let margin: CGFloat = 8
    static func panelWidth(notch: CGFloat) -> CGFloat { notch + 2 * wing + 2 * margin }

    @ObservedObject var model: LockIndicatorModel
    let notchSize: CGSize

    private let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)

    var body: some View {
        let full = notchSize.width + 2 * Self.wing
        let panelW = Self.panelWidth(notch: notchSize.width)
        ZStack(alignment: .topLeading) {
            IslandShape(width: model.expanded ? full : notchSize.width, height: notchSize.height,
                        bottomRadius: 10, notchWidth: notchSize.width)
                .fill(Color.black)
            Image(systemName: model.unlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .opacity(model.expanded ? 1 : 0)
                .scaleEffect(model.expanded ? 1 : 0.6)
                .frame(width: Self.wing, height: notchSize.height)
                .offset(x: panelW / 2 + notchSize.width / 2)
        }
        .frame(width: panelW, height: notchSize.height, alignment: .topLeading)
        .animation(spring, value: model.expanded)
        .animation(.easeOut(duration: 0.25), value: model.unlocked)
    }
}
