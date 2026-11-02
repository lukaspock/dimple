import SwiftUI

/// Battery glyph: thin outline, nub and a fill capsule. Optional bolt overlay.
struct BatteryGlyph: View {
    var percent: Int
    var tint: Color
    var showBolt = false
    var height: CGFloat = 11

    var body: some View {
        let w = height * 2
        let fill = CGFloat(min(max(percent, 0), 100)) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                Capsule().fill(tint)
                    .frame(width: max(height * 0.3, (w - 4) * fill), height: height - 4)
                    .padding(.leading, 2)
                if showBolt {
                    Image(systemName: "bolt.fill").font(.system(size: height * 0.6, weight: .bold))
                        .foregroundStyle(.white).frame(width: w).shadow(color: .black, radius: 1).shadow(color: .black.opacity(0.8), radius: 0.5)
                }
            }
            .frame(width: w, height: height)
            Capsule().fill(.white.opacity(0.4)).frame(width: 1.5, height: height * 0.36)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: percent)
    }
}

/// Expanded view: big percentage, bar and a status line.
struct BatteryExpandedView: View {
    @ObservedObject var module: BatteryModule

    var body: some View {
        let info = module.info
        let tint = module.tint(for: info)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(info.percent)%").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .contentTransition(.numericText())
                Spacer()
                if info.onAC { Image(systemName: "bolt.fill").foregroundStyle(tint).font(.system(size: 16, weight: .semibold)) }
            }
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(tint).frame(width: max(6, geo.size.width * CGFloat(info.percent) / 100))
                }
            }
            .frame(height: 6)
            Text(module.statusLine(for: info)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: info)
    }
}
