// LoopFollow
// DeviceAge.swift

import Foundation

/// How long ago the pump site or the sensor was changed, in the phone's CAGE and SAGE format.
struct DeviceAge: Equatable {
    /// Seconds since the change; 0 for a change time ahead of this clock.
    let seconds: TimeInterval

    /// Nil when the change time is unknown (0).
    init?(since changedAt: TimeInterval, now: Date) {
        guard changedAt > 0 else { return nil }
        seconds = max(0, now.timeIntervalSince1970 - changedAt)
    }

    /// In days, as the phone's coloring thresholds are.
    var days: Double {
        seconds / 86400
    }

    /// Whole days and hours, rounded down like the phone: "0d 1h", "4d 5h".
    var label: String {
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        return "\(days)d \(hours)h"
    }
}
