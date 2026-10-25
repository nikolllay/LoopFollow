// LoopFollow
// WatchSettings.swift

import Foundation

/// Phone-owned settings the Watch app needs.
///
/// The iPhone and the Watch each have their own App Group container, so values the
/// phone writes to its App Group never reach the Watch. Instead the phone sends this
/// payload over WatchConnectivity and the Watch writes it into its own App Group,
/// where Watch code reads it through `LAAppGroupSettings`.
struct WatchSettings: Codable, Equatable {
    /// WatchConnectivity payload key.
    static let payloadKey = "settings"

    var lowMgdl: Double
    var highMgdl: Double
    var remoteEnabled: Bool
    var maxBolus: Double
    var maxCarbs: Double
    var overridePresets: [WatchOverridePreset]
    var nightscoutURL: String
    var nightscoutToken: String
    /// Which remote the phone sends Watch commands through.
    var remoteSystem: WatchRemoteSystem = .loop
    /// The pump's bolus increment in units; Trio boluses must be a multiple of it.
    var bolusIncrement: Double = 0.05
    /// The phone's CAGE and SAGE coloring, which the Watch's pump and sensor ages follow; nil
    /// while it's off.
    var pumpAgeColoring: AgeColoring? = nil
    var sensorAgeColoring: AgeColoring? = nil
    /// The phone's Trio remote options; nil while Watch commands don't go through Trio.
    var trioRemote: WatchTrioRemote? = nil

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> WatchSettings {
        try JSONDecoder().decode(WatchSettings.self, from: data)
    }

    /// Persists every field into this device's App Group container.
    func applyToAppGroup() {
        LAAppGroupSettings.setThresholds(lowMgdl: lowMgdl, highMgdl: highMgdl)
        LAAppGroupSettings.setWatchRemoteEnabled(remoteEnabled)
        LAAppGroupSettings.setWatchMaxBolus(maxBolus)
        LAAppGroupSettings.setWatchMaxCarbs(maxCarbs)
        LAAppGroupSettings.setWatchOverridePresets(overridePresets)
        LAAppGroupSettings.setWatchNightscoutURL(nightscoutURL)
        LAAppGroupSettings.setWatchNightscoutToken(nightscoutToken)
        LAAppGroupSettings.setWatchRemoteSystem(remoteSystem)
        LAAppGroupSettings.setWatchBolusIncrement(bolusIncrement)
        LAAppGroupSettings.setWatchPumpAgeColoring(pumpAgeColoring)
        LAAppGroupSettings.setWatchSensorAgeColoring(sensorAgeColoring)
        LAAppGroupSettings.setWatchTrioRemote(trioRemote)
    }

    /// Reads the values back from this device's App Group container.
    static func fromAppGroup() -> WatchSettings {
        let thresholds = LAAppGroupSettings.thresholdsMgdl()
        return WatchSettings(
            lowMgdl: thresholds.low,
            highMgdl: thresholds.high,
            remoteEnabled: LAAppGroupSettings.isWatchRemoteEnabled(),
            maxBolus: LAAppGroupSettings.watchMaxBolus(),
            maxCarbs: LAAppGroupSettings.watchMaxCarbs(),
            overridePresets: LAAppGroupSettings.watchOverridePresets(),
            nightscoutURL: LAAppGroupSettings.watchNightscoutURL(),
            nightscoutToken: LAAppGroupSettings.watchNightscoutToken(),
            remoteSystem: LAAppGroupSettings.watchRemoteSystem(),
            bolusIncrement: LAAppGroupSettings.watchBolusIncrement(),
            pumpAgeColoring: LAAppGroupSettings.watchPumpAgeColoring(),
            sensorAgeColoring: LAAppGroupSettings.watchSensorAgeColoring(),
            trioRemote: LAAppGroupSettings.watchTrioRemote()
        )
    }
}
