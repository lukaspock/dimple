import SwiftUI

/// The panel is permanently as large as the biggest state; everything morphs inside it.
/// Geometry follows `model.shape`, content visibility follows `model.content` (opacity only, content is
/// always laid out at its final size).
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    private static let showFade = Animation.easeOut(duration: 0.25).delay(0.1)
    private static let hideFade = Animation.easeOut(duration: 0.15)
    private static let swap = Animation.easeOut(duration: 0.2)

    var body: some View {
        let notch = model.geometry.notchSize
        let size = model.size(for: model.shape)
        let shape = IslandShape(width: size.width, height: size.height,
                                bottomRadius: model.bottomRadius(for: model.shape), notchWidth: notch.width)
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            ZStack(alignment: .top) {
                if let compact = model.compact { compactView(compact, notch: notch) }
                if !model.expandedModules.isEmpty { expanded(notch: notch, size: size) }
            }
            .clipShape(shape)
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
        .animation(NotchViewModel.spring, value: model.layout)
        .environment(\.colorScheme, .dark)
    }

    private func compactView(_ source: NotchViewModel.CompactSource, notch: CGSize) -> some View {
        let on = model.content == .compact
        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                leading(source).frame(width: source.wing, height: notch.height)
                Spacer(minLength: 0).frame(width: notch.width)
                trailing(source).frame(width: source.wing, height: notch.height)
            }
            .id(source.key)
            .transition(.opacity)
        }
        .animation(Self.swap, value: source.key)
        .scaleEffect(on ? 1 : 0.9)
        .opacity(on ? 1 : 0)
        .animation(on ? Self.showFade : Self.hideFade, value: model.content)
        .allowsHitTesting(on)
    }

    private func leading(_ s: NotchViewModel.CompactSource) -> AnyView {
        switch s { case .module(let m): return m.makeCompactLeading(); case .notice(let n): return n.notice.makeLeading() }
    }

    private func trailing(_ s: NotchViewModel.CompactSource) -> AnyView {
        switch s { case .module(let m): return m.makeCompactTrailing(); case .notice(let n): return n.notice.makeTrailing() }
    }

    private func expanded(notch: CGSize, size: CGSize) -> some View {
        let on = model.content == .expanded
        let modules = model.expandedModules
        let selected = modules.firstIndex { $0.id == model.module?.id } ?? 0
        return ZStack(alignment: .top) {
            // All modules are laid out; the selected one is visible, the others wait to the side (crossfade + slide).
            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                let isSel = index == selected
                module.makeExpandedContent()
                    .frame(width: module.expandedContentSize.width, height: module.expandedContentSize.height)
                    .padding(.top, notch.height)
                    .offset(x: CGFloat(index - selected) * 36)
                    .opacity(isSel ? 1 : 0)
                    .allowsHitTesting(on && isSel)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            if modules.count > 1 {
                switcher(modules, selected: selected)
                    .frame(width: size.width, height: size.height, alignment: .bottom)
            }
        }
        .animation(NotchViewModel.spring, value: selected)
        .scaleEffect(on ? 1 : 0.95, anchor: .top)
        .opacity(on ? 1 : 0)
        .animation(on ? Self.showFade : Self.hideFade, value: model.content)
        .allowsHitTesting(on)
    }

    private func switcher(_ modules: [NotchModule], selected: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                Image(systemName: module.iconName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(index == selected ? 1 : 0.3))
                    .frame(width: 20, height: 14)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(module.id) }
                    .help(module.title)
            }
        }
        .padding(.bottom, 3)
        .animation(Self.swap, value: selected)
    }
}
