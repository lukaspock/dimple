import SwiftUI
import Combine

@MainActor
final class SpotifyModule: NotchModule {
    let id = "spotify"
    let priority = 100
    let title = "Spotify"
    let iconName = "music.note"
    let compactWingWidth: CGFloat = 34
    let expandedContentSize = MediaCardContent.size

    let service = SpotifyService()
    let artwork = ArtworkLoader()

    private let subject = PassthroughSubject<Void, Never>()
    private var bag = Set<AnyCancellable>()

    init() {}

    private var isExpanded = false

    /// Visible only while playing. Exception: while expanded (hovered) it stays until the hover ends.
    var isActive: Bool {
        let s = service.state
        return s.isRunning && s.hasTrack && (s.isPlaying || isExpanded)
    }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    // MARK: NotchModule

    func start() {
        guard bag.isEmpty else { return }
        // Only coarse changes (not per-second position updates) notify the registry.
        struct Key: Equatable { var active: Bool; var playing: Bool; var title: String; var artist: String }
        service.$state
            .map { Key(active: $0.isRunning && $0.hasTrack, playing: $0.isPlaying, title: $0.title, artist: $0.artist) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.notify() }.store(in: &bag)
        service.$state.map(\.artworkURL).removeDuplicates()
            .sink { [weak self] in self?.artwork.load($0) }.store(in: &bag)
        artwork.$imageURL.dropFirst().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        artwork.$accent.dropFirst().removeDuplicates().sink { [weak self] _ in self?.notify() }.store(in: &bag)
        service.start()
    }

    func stop() {
        service.stop(); artwork.cancel(); bag.removeAll()
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        service.setExpanded(expanded)
    }

    func makeCompactLeading() -> AnyView { AnyView(SpotifyCompactLeading(service: service, artwork: artwork)) }
    func makeCompactTrailing() -> AnyView { AnyView(SpotifyCompactTrailing(service: service, artwork: artwork)) }
    func makeExpandedContent() -> AnyView { AnyView(SpotifyExpandedView(service: service, artwork: artwork)) }

    private func notify() {
        // Next runloop turn so @Published values (willSet) are already updated when observers read them.
        DispatchQueue.main.async { [subject] in subject.send() }
    }
}
