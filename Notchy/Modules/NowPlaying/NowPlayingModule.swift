import SwiftUI
import Combine

/// System-wide Now Playing (browsers, Music, Podcasts, video players) except Spotify, which has its own module.
@MainActor
final class NowPlayingModule: NotchModule {
    let id = "nowplaying"
    let priority = 90
    let title = "Wiedergabe"
    let iconName = "play.circle"
    let compactWingWidth: CGFloat = 34
    let expandedContentSize = NowPlayingCardContent.size

    let model = NowPlayingModel()
    private let subject = PassthroughSubject<Void, Never>()
    private var bag = Set<AnyCancellable>()
    private var isExpanded = false

    /// Visible only while playing (stays while expanded/hovered, like Spotify).
    var isActive: Bool {
        guard model.available, let s = model.state, !s.displayTitle.isEmpty else { return false }
        return s.playing || isExpanded
    }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    func start() {
        guard bag.isEmpty else { return }
        struct Key: Equatable { var has: Bool; var playing: Bool; var title: String; var artist: String; var src: String?; var avail: Bool }
        // Coarse changes only (no per-position updates); debounced against rapid source switches.
        model.$state
            .map { [model] s in Key(has: s != nil, playing: s?.playing ?? false, title: s?.displayTitle ?? "",
                                    artist: s?.artist ?? "", src: s?.sourceBundleID, avail: model.available) }
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.subject.send() }.store(in: &bag)
        model.$available.dropFirst().removeDuplicates().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        model.$cover.dropFirst().map { $0 != nil }.removeDuplicates().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        model.start()
    }

    func stop() { model.stop(); bag.removeAll() }

    func setExpanded(_ expanded: Bool) { isExpanded = expanded }

    func makeCompactLeading() -> AnyView { AnyView(NowPlayingCompactLeading(model: model)) }
    func makeCompactTrailing() -> AnyView { AnyView(NowPlayingCompactTrailing(model: model)) }
    func makeExpandedContent() -> AnyView { AnyView(NowPlayingCardContent(model: model)) }

    private func notify() { DispatchQueue.main.async { [subject] in subject.send() } }
}
