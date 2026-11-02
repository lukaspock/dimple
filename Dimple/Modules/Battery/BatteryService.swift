import Foundation
import IOKit.ps

/// Snapshot of the internal battery.
struct BatteryInfo: Equatable {
    var percent: Int = 100
    var onAC = false
    var isCharging = false
    var isCharged = false
    /// Minutes until empty / full; nil while macOS is still calculating (or not applicable).
    var minutesToEmpty: Int?
    var minutesToFull: Int?
}

/// Event driven IOKit power source reader (no polling): `onChange` fires on every power source change.
final class BatteryService {
    var onChange: ((BatteryInfo?) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            me.onChange?(me.read())
        }
        guard let s = IOPSNotificationCreateRunLoopSource(cb, ctx)?.takeRetainedValue() else { return }
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
        source = nil
    }

    /// Current state; nil on machines without an internal battery.
    func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            var info = BatteryInfo()
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            info.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            info.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            info.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            info.isCharged = d[kIOPSIsChargedKey] as? Bool ?? false
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t >= 0 { info.minutesToEmpty = t }
            if let t = d[kIOPSTimeToFullChargeKey] as? Int, t >= 0 { info.minutesToFull = t }
            return info
        }
        return nil
    }
}
