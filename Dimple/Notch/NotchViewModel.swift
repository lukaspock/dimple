import SwiftUI
import Combine

/// Drives the island: emerge from the notch, expand on hover, retract into the notch.
/// `shape` drives geometry (one spring), `content` drives which content is visible (opacity only).
@MainActor
final class NotchViewModel: ObservableObject {
    static let expandedPadding = EdgeInsets(top: 0, leading: 22, bottom: 18, trailing: 22)
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.86)

    @Published private(set) var shape: NotchDisplayState = .hidden
    @Published private(set) var content: NotchDisplayState = .hidden
    /// True from emerge start until the retract animation finished (panel is ordered out afterwards).
    @Published private(set) var panelVisible = false
    /// Module shown in the expanded state (the selected one).
    @Published private(set) var module: NotchModule?
    /// What the compact state shows: a notice or the top module.
    @Published private(set) var compact: CompactSource?
    /// Modules reachable in the expanded state, priority order (switcher shows them when there are several).
    @Published private(set) var expandedModules: [NotchModule] = []
    @Published var geometry: NotchGeometry { didSet { recompute() } }

    let registry: ModuleRegistry
    private var isHovering = false
    private var collapseTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var emergeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private weak var expandedModule: NotchModule?
    private var dropHover = false

    @MainActor enum CompactSource {
        case module(NotchModule)
        case notice(ActiveNotice)
        var key: String {
            switch self { case .module(let m): return m.id; case .notice(let n): return "notice:" + n.key }
        }
        var wing: CGFloat {
            switch self { case .module(let m): return m.compactWingWidth; case .notice(let n): return n.wingWidth }
        }
    }

    /// Everything that morphs the island geometry with the spring.
    struct Layout: Equatable { var shape: NotchDisplayState; var moduleID: String?; var wing: CGFloat }
    var layout: Layout { Layout(shape: shape, moduleID: module?.id, wing: compact?.wing ?? 0) }

    init(registry: ModuleRegistry, geometry: NotchGeometry) {
        self.registry = registry
        self.geometry = geometry
        registry.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    // MARK: Geometry

    /// Constant size of the panel: the biggest state of any module.
    var panelSize: CGSize {
        let wide = geometry.notchSize.width + 2 * NotchNotice.maxWingWidth
        return registry.modules.reduce(CGSize(width: wide, height: geometry.notchSize.height)) { acc, m in
            let e = expandedSize(m)
            return CGSize(width: max(acc.width, e.width), height: max(acc.height, e.height))
        }
    }

    func size(for state: NotchDisplayState) -> CGSize {
        switch state {
        case .hidden: return geometry.notchSize
        case .compact:
            guard let c = compact else { return geometry.notchSize }
            return CGSize(width: geometry.notchSize.width + 2 * c.wing, height: geometry.notchSize.height)
        case .expanded:
            guard let m = module else { return geometry.notchSize }
            return expandedSize(m)
        }
    }

    func bottomRadius(for state: NotchDisplayState) -> CGFloat {
        switch state { case .hidden: return 10; case .compact: return 12; case .expanded: return 36 }
    }

    /// Screen rect (global coordinates) in which the island currently wants the mouse.
    var interactiveRect: CGRect? {
        guard panelVisible, shape != .hidden else { return nil }
        return geometry.frame(for: size(for: shape)).insetBy(dx: -2, dy: -2)
    }

    /// Area around the notch that reacts to a file drag (only used while a drag is active).
    var dropHotZone: CGRect {
        let n = geometry.notchSize
        return geometry.frame(for: CGSize(width: n.width + 140, height: n.height + 36))
    }

    private func expandedSize(_ m: NotchModule) -> CGSize {
        let p = Self.expandedPadding
        let compactW = geometry.notchSize.width + 2 * m.compactWingWidth
        return CGSize(width: max(compactW, m.expandedContentSize.width + p.leading + p.trailing),
                      height: geometry.notchSize.height + m.expandedContentSize.height + p.bottom)
    }

    // MARK: Switching and drops

    func select(_ id: String) { registry.select(id) }

    /// Step to the next (+1) / previous (-1) module in the switcher.
    func step(_ delta: Int) {
        guard shape == .expanded, expandedModules.count > 1,
              let i = expandedModules.firstIndex(where: { $0.id == module?.id }) else { return }
        let j = i + delta
        guard expandedModules.indices.contains(j) else { return }
        registry.select(expandedModules[j].id)
    }

    /// A file drag is over the notch hot zone: show the drop module expanded.
    func setDropHover(_ on: Bool) {
        guard on != dropHover else { return }
        dropHover = on
        registry.setForced(on ? registry.dropModule?.id : nil)
    }

    var registryAcceptsDrops: Bool { registry.dropModule != nil }
    var canAcceptDrop: Bool { dropHover && module?.acceptsDrops == true }

    func performDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let m = module, m.acceptsDrops else { return false }
        registry.select(m.id)
        return m.handleDrop(providers: providers)
    }

    // MARK: Hover

    func setHovering(_ hovering: Bool) {
        if hovering {
            collapseTask?.cancel(); collapseTask = nil
            guard !isHovering else { return }
            isHovering = true
            recompute()
        } else {
            guard isHovering, collapseTask == nil else { return }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.collapseTask = nil
                self.isHovering = false
                self.recompute()
            }
        }
    }

    // MARK: State

    private func recompute() {
        // Expansion is a hover state of the selected module; tell it first so `isActive` is up to date.
        var r = registry.resolve()
        let wantExpanded = isHovering && panelVisible && hideTask == nil && !r.expanded.isEmpty
        let target = wantExpanded ? r.selected : nil
        if expandedModule !== target {
            expandedModule?.setExpanded(false)
            expandedModule = target
            target?.setExpanded(true)
        }
        r = registry.resolve()
        guard r.isShown else { hide(); return }

        if hideTask != nil { hideTask?.cancel(); hideTask = nil }
        let source: CompactSource? = r.notice.map { .notice($0) } ?? r.active.first.map { .module($0) } ?? r.selected.map { .module($0) }
        if compact?.key != source?.key || compact?.wing != source?.wing { compact = source }
        if module !== r.selected { module = r.selected }
        if expandedModules.map(\.id) != r.expanded.map(\.id) { expandedModules = r.expanded }

        if !panelVisible {
            emerge()
            return
        }
        guard emergeTask == nil else { return }
        let target2: NotchDisplayState = isHovering && !r.expanded.isEmpty ? .expanded : .compact
        if shape != target2 { shape = target2 }
        if content != target2 { content = target2 }
    }

    /// Start exactly at notch size (invisible against the hardware), then grow into the wings.
    private func emerge() {
        shape = .hidden
        content = .hidden
        panelVisible = true
        emergeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)   // let the panel render the hidden state first
            guard !Task.isCancelled, let self else { return }
            self.emergeTask = nil
            self.recompute()
        }
    }

    /// Retract: content fades out, shape shrinks back into the notch, then the panel is released.
    private func hide() {
        emergeTask?.cancel(); emergeTask = nil
        guard panelVisible, hideTask == nil else { return }
        isHovering = false
        collapseTask?.cancel(); collapseTask = nil
        content = .hidden
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.shape = .hidden
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self.panelVisible = false
            self.module = nil; self.compact = nil; self.expandedModules = []
            self.hideTask = nil
        }
    }
}
