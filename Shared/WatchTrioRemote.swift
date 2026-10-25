// LoopFollow
// WatchTrioRemote.swift

import Foundation

/// What the Watch's Trio remote screens need from the phone, matching the phone's own Trio
/// remote: which meal fields its Meal screen offers and their limits, its temp target presets,
/// and Trio's overrides.
struct WatchTrioRemote: Codable, Equatable {
    /// The phone's "Meal with Bolus" and "Meal with Fat/Protein" remote settings.
    var mealWithBolus = false
    var mealWithFatProtein = false
    var maxFat: Double = 30
    var maxProtein: Double = 30
    var tempTargetPresets: [TempTargetPreset] = []
    var overrides: [Override] = []

    init(
        mealWithBolus: Bool = false,
        mealWithFatProtein: Bool = false,
        maxFat: Double = 30,
        maxProtein: Double = 30,
        tempTargetPresets: [TempTargetPreset] = [],
        overrides: [Override] = []
    ) {
        self.mealWithBolus = mealWithBolus
        self.mealWithFatProtein = mealWithFatProtein
        self.maxFat = maxFat
        self.maxProtein = maxProtein
        self.tempTargetPresets = tempTargetPresets
        self.overrides = overrides
    }

    /// Fields missing from an older or newer phone take their defaults, so a mismatch between
    /// the two apps can't stop the Watch's settings from updating.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mealWithBolus = try container.decodeIfPresent(Bool.self, forKey: .mealWithBolus) ?? false
        mealWithFatProtein = try container.decodeIfPresent(Bool.self, forKey: .mealWithFatProtein) ?? false
        maxFat = try container.decodeIfPresent(Double.self, forKey: .maxFat) ?? 30
        maxProtein = try container.decodeIfPresent(Double.self, forKey: .maxProtein) ?? 30
        tempTargetPresets = try container.decodeIfPresent([TempTargetPreset].self, forKey: .tempTargetPresets) ?? []
        overrides = try container.decodeIfPresent([Override].self, forKey: .overrides) ?? []
    }

    /// One of the presets saved on the phone's Temp Target screen.
    struct TempTargetPreset: Codable, Equatable, Hashable, Identifiable {
        var name: String
        var targetMgdl: Double
        var durationMinutes: Double

        var id: String { name }
    }

    /// One of Trio's override presets. Trio starts it by name, with its own settings; the rest is
    /// shown so it can be told apart.
    struct Override: Codable, Equatable, Hashable, Identifiable {
        var name: String
        var durationMinutes: Double?
        var percentage: Double?
        var targetMgdl: Double?

        var id: String { name }
    }

    /// The targets the phone's Temp Target screen accepts.
    static let targetRangeMgdl: ClosedRange<Double> = 80 ... 200
    /// The durations the phone's Temp Target screen accepts: from 5 minutes, up to what its
    /// four-digit field holds.
    static let durationRangeMinutes: ClosedRange<Double> = 5 ... 9999
    /// How far from now the Watch can log a meal: earlier, for one already eaten, or later.
    static let mealTimeOffsetRangeMinutes: ClosedRange<Double> = -180 ... 180
}
