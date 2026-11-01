import SwiftUI
import Combine

/// Visual state of the notch island.
enum NotchDisplayState: Equatable {
    case hidden
    case compact
    case expanded
}

/// A feature that can live inside the notch (Spotify, calendar, timer, battery, file shelf, ...).
/// The core never knows concrete module types; it only renders what a module provides.
@MainActor
protocol NotchModule: AnyObject {
    /// Stable identifier, e.g. "spotify".
    var id: String { get }

    /// Higher priority wins when several modules are active at once.
    var priority: Int { get }

    /// True when the module has something to show (compact state). When no module is active the notch is hidden.
    var isActive: Bool { get }

    /// Fires whenever `isActive` or any rendered content changes (used by the registry to refresh).
    var changes: AnyPublisher<Void, Never> { get }

    /// Extra width the compact state needs on each side of the physical notch.
    var compactWingWidth: CGFloat { get }

    /// Content left of the notch in compact state (e.g. album cover).
    func makeCompactLeading() -> AnyView

    /// Content right of the notch in compact state (e.g. equalizer / play icon).
    func makeCompactTrailing() -> AnyView

    /// Full content in expanded state. Core adds the outer padding; the module fills its area.
    func makeExpandedContent() -> AnyView

    /// Preferred size of the expanded content area (excluding the notch height itself).
    var expandedContentSize: CGSize { get }

    /// Core tells the module whether it is currently expanded (so it can poll faster / animate).
    func setExpanded(_ expanded: Bool)

    /// Called once after registration.
    func start()
    func stop()

    // MARK: Optional (defaults in the extension below)

    /// A transient notice ("charging started", "timer done"). Return the same `id` while it is current; the core
    /// shows it in compact state even if the module is inactive, auto-dismisses it after `duration`, and does not
    /// re-show a dismissed id until the module stops returning it (return nil to withdraw early).
    /// Fire `changes` when this value changes.
    var notice: NotchNotice? { get }

    /// Name and SF Symbol shown in the module switcher (expanded state, only when several modules are active).
    var title: String { get }
    var iconName: String { get }

    /// File shelf style modules: the island expands to this module while a drag hovers the notch, then `handleDrop` runs.
    var acceptsDrops: Bool { get }
    func handleDrop(providers: [NSItemProvider]) -> Bool
}

extension NotchModule {
    var notice: NotchNotice? { nil }
    var title: String { id.capitalized }
    var iconName: String { "square.grid.2x2" }
    var acceptsDrops: Bool { false }
    func handleDrop(providers: [NSItemProvider]) -> Bool { false }
}

/// Transient compact-state message published by a module. Views are built lazily on the main actor; use
/// observed objects inside them for live content (the closures are not re-run on module changes).
@MainActor
struct NotchNotice: Identifiable {
    nonisolated static let maxWingWidth: CGFloat = 90

    let id: String
    /// Seconds until auto-dismiss; <= 0 keeps it until the module withdraws it.
    var duration: TimeInterval
    /// Higher wins in the queue (and may preempt a lower-priority notice that is currently shown).
    var priority: Int
    /// Width on each side of the notch; nil = the module's `compactWingWidth` (clamped to `maxWingWidth`).
    var wingWidth: CGFloat?
    let makeLeading: () -> AnyView
    let makeTrailing: () -> AnyView

    init<L: View, T: View>(id: String, duration: TimeInterval = 3, priority: Int = 0, wingWidth: CGFloat? = nil,
                           @ViewBuilder leading: @escaping () -> L, @ViewBuilder trailing: @escaping () -> T) {
        self.id = id; self.duration = duration; self.priority = priority; self.wingWidth = wingWidth
        makeLeading = { AnyView(leading()) }; makeTrailing = { AnyView(trailing()) }
    }
}
