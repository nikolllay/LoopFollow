// LoopFollow
// GlucoseSnapshotBatteryTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct GlucoseSnapshotBatteryTests {
    private func snapshot(batteryIsCharging: Bool?) -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: 120,
            delta: 2,
            trend: .flat,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            iob: nil,
            cob: nil,
            projected: nil,
            battery: 60,
            batteryIsCharging: batteryIsCharging,
            pumpReservoirU: 59,
            unit: .mgdl,
            isNotLooping: false
        )
    }

    private func roundTrip(_ snapshot: GlucoseSnapshot) throws -> GlucoseSnapshot {
        try JSONDecoder().decode(GlucoseSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    @Test("#the phone's battery, charging and the pump's reservoir reach the Watch")
    func roundTripsBattery() throws {
        let decoded = try roundTrip(snapshot(batteryIsCharging: true))
        #expect(decoded.battery == 60)
        #expect(decoded.batteryIsCharging == true)
        #expect(decoded.pumpReservoirU == 59)
        #expect(try roundTrip(snapshot(batteryIsCharging: false)).batteryIsCharging == false)
    }

    @Test("#a snapshot from a phone that doesn't send charging reads as unknown")
    func chargingMissing() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(batteryIsCharging: true))) as? [String: Any])
        json["batteryIsCharging"] = nil
        let decoded = try JSONDecoder().decode(GlucoseSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.batteryIsCharging == nil)
        #expect(decoded.battery == 60)
    }

    @Test("#renewing the Live Activity keeps the charging state")
    func renewalKeepsCharging() {
        #expect(snapshot(batteryIsCharging: true).withRenewalOverlay(true).batteryIsCharging == true)
    }
}
