import AppKit
import SwiftUI
import Combine

/// Owns the panel. The panel has a constant frame (biggest island state, flush with the top of the screen);
/// all morphing happens in SwiftUI. Mouse events are accepted only while the pointer is over the island,
/// so everything else on screen stays clickable.
@MainActor
final class NotchWindowController {
    private let panel = NotchPanel()
    private let model: NotchViewModel
    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragStartCount = 0
    private var dragActive = false
    private var scrollAcc: CGFloat = 0
    private var scrollFired = false
    private var lastScrollSwitch = Date.distantPast

    init(registry: ModuleRegistry) {
        model = NotchViewModel(registry: registry, geometry: .current())
        let host = NotchHostingView(rootView: NotchRootView(model: model))
        // Plain container as contentView: NSHostingView directly as contentView updates window size extrema
        // from inside the constraints pass and crashes when the panel is resized.
        let container = NotchContainerView()
        container.addSubview(host)
        container.canAccept = { [weak self] in self?.model.canAcceptDrop ?? false }
        container.onDrop = { [weak self] providers in
            guard let self else { return false }
            let ok = self.model.performDrop(providers)
            self.endDrag()
            return ok
        }
        container.onDragEnd = { [weak self] in self?.endDrag() }
        panel.contentView = container
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        updateFrame()

        model.$panelVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible { self.updateFrame(); self.panel.orderFrontRegardless() } else { self.panel.orderOut(nil) }
                self.pointerMoved()
            }
            .store(in: &cancellables)

        model.$shape
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pointerMoved() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.geometry = .current()
                self.updateFrame()
            }
            .store(in: &cancellables)

        // Drag detection: the drag pasteboard changes when a drag session starts after the mouse went down.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            let type = event.type
            Task { @MainActor in self?.globalMouse(type) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.scrolled(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.pointerMoved()
            return event
        } as Any)
    }

    private func updateFrame() {
        panel.setFrame(model.geometry.frame(for: model.panelSize), display: true)
    }

    private func globalMouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: dragStartCount = dragPasteboard.changeCount; endDrag()
        case .leftMouseUp: endDrag()
        case .leftMouseDragged:
            if !dragActive, dragPasteboard.changeCount != dragStartCount, dragPasteboard.pasteboardItems?.isEmpty == false {
                dragActive = true
            }
            pointerMoved()
        default: pointerMoved()
        }
    }

    private func endDrag() {
        guard dragActive else { return }
        dragActive = false
        pointerMoved()
    }

    /// Hover detection without tracking areas (works although the app is never active).
    /// While a file drag is active and a module accepts drops, the area around the notch also counts.
    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let inIsland = model.interactiveRect?.contains(p) ?? false
        let dropping = dragActive && model.registryAcceptsDrops
        let inside = inIsland || (dropping && model.dropHotZone.contains(p))
        model.setDropHover(dropping && inside)
        panel.ignoresMouseEvents = !inside
        model.setHovering(inside)
    }

    /// Two-finger horizontal swipe (or horizontal wheel) over the island switches modules.
    private func scrolled(_ event: NSEvent) {
        guard event.window === panel else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { scrollAcc = 0; scrollFired = false }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            scrollAcc += event.scrollingDeltaX
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 1
            let ready = event.hasPreciseScrollingDeltas ? !scrollFired : Date().timeIntervalSince(lastScrollSwitch) > 0.35
            if ready, abs(scrollAcc) >= threshold {
                scrollFired = true; lastScrollSwitch = Date()
                model.step(scrollAcc < 0 ? 1 : -1)
                scrollAcc = 0
            }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { scrollAcc = 0; scrollFired = false }
    }
}

/// Keeps the hosting view exactly as large as the panel (autoresizing masks fail when starting from a zero frame).
/// Also the drag destination for modules that accept drops.
final class NotchContainerView: NSView {
    var canAccept: () -> Bool = { false }
    var onDrop: ([NSItemProvider]) -> Bool = { _ in false }
    var onDragEnd: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        subviews.first?.frame = bounds
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { canAccept() ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { canAccept() ? .copy : [] }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragEnd() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var providers: [NSItemProvider] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            providers = urls.map { NSItemProvider(object: $0 as NSURL) }
        } else if let strings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String], !strings.isEmpty {
            providers = strings.map { NSItemProvider(object: $0 as NSString) }
        } else if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            providers = images.map { NSItemProvider(object: $0) }
        }
        return !providers.isEmpty && onDrop(providers)
    }
}
