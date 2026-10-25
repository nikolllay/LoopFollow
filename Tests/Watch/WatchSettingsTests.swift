// LoopFollow
// WatchSettingsTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct WatchSettingsTests {
    private let sample = WatchSettings(
        lowMgdl: 72,
        highMgdl: 190,
        remoteEnabled: true,
        maxBolus: 4.5,
        maxCarbs: 80,
        overridePresets: [
            WatchOverridePreset(name: "Exercise", symbol: "🏃", durationSeconds: 3600),
            WatchOverridePreset(name: "Sick", symbol: nil, durationSeconds: 0),
        ],
        nightscoutURL: "https://example.nightscout.test",
        nightscoutToken: "token-123",
        remoteSystem: .trio,
        bolusIncrement: 0.025,
        pumpAgeColoring: AgeColoring(warningDays: 3.5, urgentDays: 4),
        sensorAgeColoring: AgeColoring(warningDays: 9, urgentDays: nil),
        trioRemote: WatchTrioRemote(
            mealWithBolus: true,
            mealWithFatProtein: true,
            maxFat: 40,
            maxProtein: 50,
            tempTargetPresets: [.init(name: "Exercise", targetMgdl: 150, durationMinutes: 60)],
            overrides: [
                .init(name: "Sick", durationMinutes: 120, percentage: 120, targetMgdl: 100),
                .init(name: "Indefinite", durationMinutes: nil, percentage: nil, targetMgdl: nil),
            ]
        )
    )

    @Test("#settings survive the WatchConnectivity encoding")
    func encodedRoundTrip() throws {
        let decoded = try WatchSettings.decoded(from: sample.encoded())
        #expect(decoded == sample)
    }

    @Test("#applying to the App Group and reading back yields the same settings")
    func appGroupRoundTrip() {
        let previous = WatchSettings.fromAppGroup()
        defer { previous.applyToAppGroup() }

        sample.applyToAppGroup()
        #expect(WatchSettings.fromAppGroup() == sample)
    }

    @Test("#coloring that is off, and no Trio remote, read back as such")
    func coloringOff() {
        let previous = WatchSettings.fromAppGroup()
        defer { previous.applyToAppGroup() }

        var settings = sample
        settings.pumpAgeColoring = nil
        settings.sensorAgeColoring = nil
        settings.trioRemote = nil
        settings.applyToAppGroup()
        #expect(WatchSettings.fromAppGroup() == settings)
    }

    @Test("#Trio remote options missing fields read with their defaults")
    func trioRemoteMissingFields() throws {
        let decoded = try JSONDecoder().decode(WatchTrioRemote.self, from: Data(#"{"mealWithBolus":true}"#.utf8))
        #expect(decoded.mealWithBolus)
        #expect(!decoded.mealWithFatProtein)
        #expect(decoded.maxFat == 30)
        #expect(decoded.overrides.isEmpty)
    }

    @Test("#a malformed payload is rejected rather than half-applied")
    func malformedPayloadThrows() {
        #expect(throws: (any Error).self) {
            try WatchSettings.decoded(from: Data("{\"lowMgdl\":70}".utf8))
        }
    }
}
