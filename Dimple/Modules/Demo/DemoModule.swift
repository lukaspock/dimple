#if DEBUG
import SwiftUI
import Combine

/// Debug-only module (DIMPLE_DEMO=1; =2 adds a second one): always active, publishes a notice every 10 s, accepts drops.
/// Exists to test notices, the switcher and drops next to Spotify.
@MainActor
final class DemoModule: NotchModule, ObservableObject {
    let id: String
    let priority: Int
    let compactWingWidth: CGFloat = 30
    let expandedContentSize = CGSize(width: 340, height: 120)
    let title: String
    let iconName: String
    init(id: String = "demo", priority: Int = 50, iconName: String = "sparkles") {
        self.id = id; self.priority = priority; self.iconName = iconName; title = id.capitalized
    }
    let acceptsDrops = true
    var isActive: Bool { true }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    @Published private var dropped = "Drop a file here"
    private let subject = PassthroughSubject<Void, Never>()
    private var timer: Timer?
    private var count = 0
    private(set) var notice: NotchNotice?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.fire() }
    }

    func stop() { timer?.invalidate() }
    func setExpanded(_ expanded: Bool) {}

    private func fire() {
        count += 1
        let n = count
        notice = NotchNotice(id: "demo-\(n)", duration: 3, priority: 10, wingWidth: 64,
            leading: { Image(systemName: "bolt.fill").foregroundStyle(.green) },
            trailing: { Text("Demo \(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white) })
        subject.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice?.id == "demo-\(n)" { self?.notice = nil; self?.subject.send() }
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: NSURL.self) { [weak self] url, _ in
                let name = (url as? URL)?.lastPathComponent
                Task { @MainActor in self?.dropped = name.map { "Dropped: \($0)" } ?? "Dropped" }
            }
        }
        return true
    }

    func makeCompactLeading() -> AnyView { AnyView(Image(systemName: iconName).foregroundStyle(.white.opacity(0.8))) }
    func makeCompactTrailing() -> AnyView { AnyView(EmptyView()) }
    func makeExpandedContent() -> AnyView { AnyView(DemoExpanded(module: self)) }

    private struct DemoExpanded: View {
        @ObservedObject var module: DemoModule
        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: module.iconName).font(.system(size: 22))
                Text(module.title).font(.system(size: 15, weight: .semibold))
                Text(module.dropped).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white)
        }
    }
}
#endif
