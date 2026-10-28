// LoopFollow
// WatchTreatmentListTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct WatchTreatmentListTests {
    private func entries(_ json: [[String: Any]], unit: GlucoseSnapshot.Unit = .mgdl) -> [WatchTreatmentEntry] {
        WatchTreatmentList.entries(from: json, unit: unit)
    }

    private func at(_ minute: Int) -> String {
        String(format: "2026-10-28T10:%02d:00.000Z", minute)
    }

    @Test("#carbs and boluses read as the phone shows them")
    func carbsAndBoluses() {
        let rows = entries([
            ["_id": "a", "eventType": "Carb Correction", "created_at": at(1), "carbs": 20],
            ["_id": "b", "eventType": "Correction Bolus", "created_at": at(2), "insulin": 1.5],
            ["_id": "c", "eventType": "Bolus", "created_at": at(3), "insulin": 0.3, "automatic": true],
            ["_id": "d", "eventType": "Correction Bolus", "created_at": at(4), "insulin": 0.2, "type": "SMB"],
            ["_id": "e", "eventType": "SMB", "created_at": at(5), "insulin": 0.1],
        ])
        #expect(rows.map(\.kind) == [.smb, .smb, .automaticBolus, .bolus, .carbs])
        #expect(rows.last?.title == "20g")
        #expect(rows.first(where: { $0.kind == .bolus })?.title == "1.50 U")
        #expect(rows.first(where: { $0.kind == .automaticBolus })?.subtitle == "Automatic Bolus")
    }

    @Test("#a Meal Bolus gives a carbs row and a bolus row")
    func mealBolus() {
        let rows = entries([["_id": "m", "eventType": "Meal Bolus", "created_at": at(1), "carbs": 45, "insulin": 3.25]])
        #expect(Set(rows.map(\.kind)) == [.carbs, .bolus])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test("#temp basals, overrides and temp targets")
    func basalsOverridesTargets() {
        let rows = entries([
            ["_id": "t", "eventType": "Temp Basal", "created_at": at(1), "rate": 0.35, "duration": 30],
            ["_id": "o", "eventType": "Temporary Override", "created_at": at(2), "duration": 60, "notes": "Exercise"],
            ["_id": "g", "eventType": "Temporary Target", "created_at": at(3), "duration": 45, "targetBottom": 140, "targetTop": 140, "reason": "Activity"],
        ], unit: .mmol)
        #expect(rows.first(where: { $0.kind == .tempBasal })?.title == "0.35 U/hr")
        let override = rows.first { $0.kind == .override }
        #expect(override?.title == "Exercise")
        #expect(override?.subtitle == "Override · 60m")
        let target = rows.first { $0.kind == .tempTarget }
        #expect(target?.title == "7.8 mmol/L")
        #expect(target?.subtitle == "Temp Target · 45m · Activity")
    }

    @Test("#a cancelled override or target, zero amounts and unknown events are left out")
    func leftOut() {
        let rows = entries([
            ["_id": "1", "eventType": "Temporary Override", "created_at": at(1), "duration": 0],
            ["_id": "2", "eventType": "Temporary Target", "created_at": at(2), "duration": 0, "targetBottom": 100],
            ["_id": "3", "eventType": "Correction Bolus", "created_at": at(3), "insulin": 0],
            ["_id": "4", "eventType": "Site Change", "created_at": at(4)],
            ["_id": "5", "eventType": "Carb Correction", "created_at": "not a date", "carbs": 10],
        ])
        #expect(rows.isEmpty)
    }

    @Test("#an entry already loaded isn't listed twice")
    func skipsSeen() {
        let json: [[String: Any]] = [["_id": "a", "eventType": "Carb Correction", "created_at": at(1), "carbs": 20]]
        #expect(WatchTreatmentList.entries(from: json + json, unit: .mgdl).count == 1)
        #expect(WatchTreatmentList.entries(from: json, unit: .mgdl, skipping: ["a"]).isEmpty)
    }

    @Test("#where the next page starts counts every treatment, listed or not")
    func pageBounds() {
        let page = WatchTreatmentList.page(from: [
            ["_id": "a", "eventType": "Carb Correction", "created_at": at(5), "carbs": 20],
            ["_id": "b", "eventType": "Site Change", "created_at": at(1)],
        ], unit: .mgdl)
        #expect(page.entries.count == 1)
        #expect(page.ids == ["a", "b"])
        #expect(page.oldest == WatchTreatmentList.parseDate(at(1)))
    }

    @Test("#Nightscout times with or without fractions and offsets")
    func dates() {
        let utc = Date(timeIntervalSince1970: 1_793_181_600) // 2026-10-28T10:00:00Z
        #expect(WatchTreatmentList.parseDate("2026-10-28T10:00:00Z") == utc)
        #expect(WatchTreatmentList.parseDate("2026-10-28T10:00:00.000Z") == utc)
        #expect(WatchTreatmentList.parseDate("2026-10-28T12:00:00+02:00") == utc)
        #expect(WatchTreatmentList.parseDate("2026-10-28T10:00:00") == utc)
        #expect(WatchTreatmentList.parseDate("yesterday") == nil)
    }
}
