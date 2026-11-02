import SwiftUI
import Combine

/// A notice together with the module that published it.
@MainActor
struct ActiveNotice {
    let module: NotchModule
    let notice: NotchNotice
    var key: String { "\(module.id)/\(notice.id)" }
    var wingWidth: CGFloat { min(notice.wingWidth ?? module.compactWingWidth, NotchNotice.maxWingWidth) }
}

/// Holds all modules; decides what the island shows (notice / module in compact, selected module expanded).
@MainActor
final class ModuleRegistry: ObservableObject {
    /// Live snapshot of what should be shown.
    struct Resolved {
        var active: [NotchModule]           // active modules, highest priority first
        var expanded: [NotchModule]         // modules reachable in the expanded state (active + drop target)
        var selected: NotchModule?          // module shown when expanded
        var notice: ActiveNotice?
        var isShown: Bool { notice != nil || !expanded.isEmpty }
    }

    let modules: [NotchModule]
    @Published private(set) var activeModules: [NotchModule] = []
    @Published private(set) var selectedModuleID: String?
    @Published private(set) var currentNotice: ActiveNotice?
    /// Set while a drag hovers the notch: forces this (possibly inactive) module to be shown expanded.
    @Published private(set) var forcedModuleID: String?
    /// Bumped on every change so observers refresh even if the published values stay the same.
    @Published private(set) var revision = 0

    private var queue: [(item: ActiveNotice, seq: Int)] = []
    private var dismissed = Set<String>()
    private var seq = 0
    private var noticeTimer: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(modules: [NotchModule]? = nil) {
        self.modules = modules ?? ModuleRegistry.makeDefaultModules()
    }

    static func makeDefaultModules() -> [NotchModule] {
        var list: [NotchModule] = [
            SpotifyModule(), NowPlayingModule(), TimerModule.shared, CalendarModule(), BatteryModule(),
        ]
        #if DEBUG
        let demo = ProcessInfo.processInfo.environment["DIMPLE_DEMO"]
        if demo == "1" || demo == "2" { list.append(DemoModule()) }
        if demo == "2" { list.append(DemoModule(id: "demo2", priority: 40, iconName: "bolt.fill")) }
        #endif
        return list
    }

    func start() {
        modules.forEach { module in
            module.changes
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.refresh() }
                .store(in: &cancellables)
            module.start()
        }
        refresh()
    }

    func stop() {
        cancellables.removeAll()
        noticeTimer?.cancel()
        modules.forEach { $0.stop() }
    }

    // MARK: Queries

    var dropModule: NotchModule? { modules.first { $0.acceptsDrops } }

    /// Evaluated live (not cached) so callers see up-to-date `isActive` values.
    func resolve() -> Resolved {
        let active = modules.filter(\.isActive).sorted { $0.priority > $1.priority }
        var expanded = active
        let forced = forcedModuleID.flatMap { id in modules.first { $0.id == id } }
        if let forced, !expanded.contains(where: { $0 === forced }) { expanded.append(forced) }
        let selected = forced ?? expanded.first { $0.id == selectedModuleID } ?? expanded.first
        return Resolved(active: active, expanded: expanded, selected: selected, notice: currentNotice)
    }

    // MARK: Actions

    func select(_ id: String) {
        guard selectedModuleID != id else { return }
        selectedModuleID = id
        revision += 1
    }

    func setForced(_ id: String?) {
        guard forcedModuleID != id else { return }
        forcedModuleID = id
        revision += 1
    }

    // MARK: Refresh

    private func refresh() {
        let r = resolve()
        if activeModules.map(\.id) != r.active.map(\.id) { activeModules = r.active }
        syncNotices()
        revision += 1
    }

    private func syncNotices() {
        let published = modules.compactMap { m in m.notice.map { ActiveNotice(module: m, notice: $0) } }
        let keys = Set(published.map(\.key))
        dismissed.formIntersection(keys)
        queue.removeAll { !keys.contains($0.item.key) }
        // Refresh queued/current content with the latest values.
        for i in queue.indices { if let p = published.first(where: { $0.key == queue[i].item.key }) { queue[i].item = p } }
        if let cur = currentNotice {
            if let p = published.first(where: { $0.key == cur.key }) { currentNotice = p } else { clearCurrent() }
        }
        let known = Set(queue.map(\.item.key)).union(currentNotice.map { [$0.key] } ?? [])
        for p in published where !known.contains(p.key) && !dismissed.contains(p.key) {
            seq += 1; queue.append((p, seq))
        }
        // Next notice: highest priority first, FIFO among equals; may preempt a lower-priority current one.
        guard let best = queue.min(by: { ($0.item.notice.priority, -$0.seq) > ($1.item.notice.priority, -$1.seq) }) else { return }
        if let cur = currentNotice, cur.notice.priority >= best.item.notice.priority { return }
        queue.removeAll { $0.item.key == best.item.key }
        if let cur = currentNotice { seq += 1; queue.append((cur, seq)); clearCurrent() }
        show(best.item)
    }

    private func show(_ item: ActiveNotice) {
        currentNotice = item
        noticeTimer?.cancel()
        let d = item.notice.duration
        guard d > 0 else { return }
        let key = item.key
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            guard !Task.isCancelled, let self, self.currentNotice?.key == key else { return }
            self.dismissed.insert(key)
            self.clearCurrent()
            self.refresh()
        }
    }

    private func clearCurrent() {
        noticeTimer?.cancel(); noticeTimer = nil
        currentNotice = nil
    }
}
