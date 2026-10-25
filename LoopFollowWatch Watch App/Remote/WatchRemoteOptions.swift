// LoopFollow
// WatchRemoteOptions.swift

import Foundation

/// The phone's remote settings as the Watch's remote screens use them. Each screen reads them
/// once, not on every turn of the crown.
struct WatchRemoteOptions {
    let system: WatchRemoteSystem
    /// Loop rounds on its side, so it keeps 0.05U steps. Trio delivers exactly the amount sent,
    /// so it steps in the pump's increment.
    let bolusStep: Double
    let maxBolus: Double
    let maxCarbs: Double
    /// What the phone's Trio remote offers; its defaults when the phone hasn't said.
    let trio: WatchTrioRemote

    init() {
        system = LAAppGroupSettings.watchRemoteSystem()
        bolusStep = system == .trio ? max(0.001, LAAppGroupSettings.watchBolusIncrement()) : 0.05
        let maxBolus = max(bolusStep, LAAppGroupSettings.watchMaxBolus())
        self.maxBolus = system == .trio ? maxBolus.roundedDown(toStep: bolusStep) : maxBolus
        maxCarbs = max(5, LAAppGroupSettings.watchMaxCarbs())
        trio = LAAppGroupSettings.watchTrioRemote() ?? WatchTrioRemote()
    }

    /// Two decimals, or three for pumps with a 0.025U increment.
    func insulin(_ units: Double) -> String {
        let hundredths = bolusStep * 100
        let digits = abs(hundredths - hundredths.rounded()) < 1e-9 ? 2 : 3
        return String(format: "%.\(digits)f", units)
    }

    /// Caps a suggested bolus at the max bolus; for Trio it also rounds down to the increment.
    func bolusPrefill(_ units: Double) -> Double {
        let capped = min(units, maxBolus)
        return system == .trio ? capped.roundedDown(toStep: bolusStep) : capped.rounded(toPlaces: 2)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }

    /// The nearest multiple of `step`, without the floating-point noise the crown adds.
    func snapped(toStep step: Double) -> Double {
        guard step > 0 else { return self }
        return ((self / step).rounded() * step).rounded(toPlaces: 3)
    }

    func roundedDown(toStep step: Double) -> Double {
        guard step > 0 else { return self }
        return ((self / step + 1e-9).rounded(.down) * step).rounded(toPlaces: 3)
    }
}
