import AppKit
import os

/// The ONLY place that touches private SkyLight (WindowServer) APIs. All symbols are resolved with dlsym; if any is
/// missing (new macOS), `isAvailable` is false and every call is a harmless no-op. Used to place windows into a
/// custom space with an absolute level above the lock screen (same technique as boring.notch / Atoll "CGSSpace").
final class SkyLightBridge {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpacesOp = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias SpaceDestroy = @convention(c) (Int32, Int32) -> Int32

    private static let log = Logger(subsystem: "com.dimple.Dimple", category: "SkyLight")

    private let connection: Int32
    private let create: SpaceCreate
    private let setLevel: SpaceSetLevel
    private let show: SpacesOp
    private let hide: SpacesOp
    private let addWindows: SpaceAddWindows
    private let destroy: SpaceDestroy

    private(set) var space: Int32 = 0
    /// Result codes of the last operations, for diagnostics ("create=<id> level=0 show=0 add=0").
    private(set) var report = ""

    /// Fails (returns nil) if the framework or any required symbol is missing.
    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            Self.log.error("SkyLight not loadable; lock screen widgets disabled")
            return nil
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { Self.log.error("missing symbol \(name, privacy: .public)"); return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let main = sym("SLSMainConnectionID", MainConnection.self),
              let create = sym("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let show = sym("SLSShowSpaces", SpacesOp.self),
              let hide = sym("SLSHideSpaces", SpacesOp.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", SpaceAddWindows.self),
              let destroy = sym("SLSSpaceDestroy", SpaceDestroy.self) else { return nil }
        connection = main()
        self.create = create; self.setLevel = setLevel; self.show = show
        self.hide = hide; self.addWindows = add; self.destroy = destroy
    }

    /// Creates and shows a fresh space above everything (level 400). Returns false on failure.
    @discardableResult
    func openSpace(level: Int32 = 400) -> Bool {
        closeSpace()
        let id = create(connection, 1, 0)
        guard id != 0 else { report = "create failed"; Self.log.error("SLSSpaceCreate returned 0"); return false }
        space = id
        let l = setLevel(connection, id, level)
        let s = show(connection, [id] as CFArray)
        report = "create=\(id) level=\(l) show=\(s)"
        NSLog("[SkyLight] %@", report)
        return l == 0  // SLSShowSpaces return value is unreliable (may be void)
    }

    /// Moves the window (it must be on screen so it has a window number) into the custom space.
    @discardableResult
    func add(_ window: NSWindow) -> Bool {
        guard space != 0, window.windowNumber > 0 else { return false }
        let r = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        report += " add(\(window.windowNumber))=\(r)"
        NSLog("[SkyLight] add %d -> %d", window.windowNumber, r)
        return r == 0
    }

    func closeSpace() {
        guard space != 0 else { return }
        _ = hide(connection, [space] as CFArray)
        _ = destroy(connection, space)
        space = 0
    }
}
