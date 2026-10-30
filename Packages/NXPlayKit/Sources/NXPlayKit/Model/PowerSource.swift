import Foundation
import IOKit.ps

/// What powers the Mac: the power adapter, or its battery. A desktop Mac is always on the adapter.
enum PowerSource {
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
