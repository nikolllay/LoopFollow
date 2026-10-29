// LoopFollow
// WatchAppSettings.swift

import Combine
import Foundation

final class WatchAppSettings: ObservableObject {
    static let shared = WatchAppSettings()
    private init() {}

    // MARK: - Display

    /// Colors BG on a continuous hue ramp; also applies to complications.
    var dynamicBGColor: Bool {
        get { GlucoseColor.isDynamic }
        set {
            GlucoseColor.isDynamic = newValue
            objectWillChange.send()
            WatchSessionReceiver.shared.reloadComplications()
        }
    }
}
