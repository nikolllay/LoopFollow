// LoopFollow
// WatchTreatmentHistoryTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct WatchTreatmentHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let english = Locale(identifier: "en_US")

    private func treatment(_ kind: WatchTreatmentHistory.Kind, minutesAgo: Double, label: String = "", mgdl: Int = 150) -> WatchTreatmentHistory.Treatment {
        .init(kind: kind, date: now.timeIntervalSince1970 - minutesAgo * 60, mgdl: mgdl, label: label)
    }

    @Test("#keeps only treatments inside the window, oldest first")
    func trimsAndSorts() {
        let history = WatchTreatmentHistory.make(
            from: [treatment(.smb, minutesAgo: 5), treatment(.carbs, minutesAgo: 200), treatment(.bolus, minutesAgo: 30)],
            asOf: now.timeIntervalSince1970 - 60,
            now: now
        )
        #expect(history.treatments.map(\.kind) == [.bolus, .smb])
        #expect(history.generatedAt == now.timeIntervalSince1970)
        #expect(history.asOf == now.timeIntervalSince1970 - 60)
    }

    @Test("#drops treatments dated in the future")
    func dropsFuture() {
        let history = WatchTreatmentHistory.make(from: [treatment(.bolus, minutesAgo: -10)], asOf: nil, now: now)
        #expect(history.treatments.isEmpty)
    }

    @Test("#survives the WatchConnectivity encoding, with and without a download time")
    func encodedRoundTrip() throws {
        for asOf in [nil, now.timeIntervalSince1970 - 120] {
            let history = WatchTreatmentHistory.make(
                from: [treatment(.bolus, minutesAgo: 20, label: "1.5"), treatment(.carbs, minutesAgo: 25, label: "30 3h")],
                asOf: asOf,
                now: now
            )
            let decoded = try WatchTreatmentHistory.decoded(from: history.encoded())
            #expect(decoded == history)
        }
    }

    @Test("#isolated treatments keep their true time")
    func spreadLeavesIsolatedAlone() {
        let dates: [TimeInterval] = [0, 1200, 2400]
        #expect(WatchTreatmentHistory.spreadDates(dates, minGap: 240, maxShift: 240) == dates)
    }

    @Test("#crowded treatments move left only, never past maxShift, newest stays put")
    func spreadMovesCrowdedLeft() {
        let dates: [TimeInterval] = [0, 60, 120, 180]
        let drawn = WatchTreatmentHistory.spreadDates(dates, minGap: 240, maxShift: 240)
        #expect(drawn.last == dates.last)
        for (actual, shown) in zip(dates, drawn) {
            #expect(shown <= actual)
            #expect(shown >= actual - 240)
        }
        #expect(drawn == drawn.sorted())
    }

    @Test("#two close treatments end up a full gap apart when there is room")
    func spreadOpensGap() {
        let drawn = WatchTreatmentHistory.spreadDates([1000, 1100], minGap: 240, maxShift: 240)
        #expect(drawn == [860, 1100])
    }

    @Test("#SMBs five minutes apart are not moved, like on the iPhone")
    func smbsFiveMinutesApartStay() {
        let treatments = [treatment(.smb, minutesAgo: 15), treatment(.smb, minutesAgo: 10), treatment(.smb, minutesAgo: 5)]
        let drawn = WatchTreatmentHistory.drawn(treatments, insulinGap: 240, carbGap: 250, secondsPerLabelUnit: 300, mgdlPerLabelHeight: 20)
        #expect(drawn.map(\.drawnDate) == treatments.map(\.date))
    }

    @Test("#a bolus label wins over a nearby SMB label")
    func bolusLabelBeatsSMB() {
        let treatments = [treatment(.bolus, minutesAgo: 10, label: "1.5"), treatment(.smb, minutesAgo: 5, label: ".2")]
        let drawn = WatchTreatmentHistory.drawn(treatments, insulinGap: 240, carbGap: 250, secondsPerLabelUnit: 300, mgdlPerLabelHeight: 20)
        let labelled = drawn.filter(\.showsLabel).map(\.treatment.kind)
        #expect(labelled == [.bolus])
    }

    @Test("#SMB labels are shown where they fit, newest first")
    func smbLabelsWhereTheyFit() {
        // SMBs every 5 minutes: two ".2" labels need about 10 minutes at 300 s per digit width.
        let treatments = (0 ..< 4).map { treatment(.smb, minutesAgo: Double(5 + $0 * 5), label: ".2") }
        let drawn = WatchTreatmentHistory.drawn(treatments, insulinGap: 240, carbGap: 250, secondsPerLabelUnit: 300, mgdlPerLabelHeight: 20)
            .sorted { $0.drawnDate > $1.drawnDate }
        #expect(drawn.map(\.showsLabel) == [true, false, true, false])
    }

    @Test("#labels close in time but far apart in height are both shown")
    func labelsApartInHeightBothShow() {
        // Like an SMB drawn near the top and the next one drawn much lower, five minutes later.
        let treatments = [treatment(.smb, minutesAgo: 10, label: ".05", mgdl: 200), treatment(.smb, minutesAgo: 5, label: ".2", mgdl: 125)]
        let drawn = WatchTreatmentHistory.drawn(treatments, insulinGap: 240, carbGap: 250, secondsPerLabelUnit: 300, mgdlPerLabelHeight: 20)
        let allLabelled = drawn.allSatisfy { $0.showsLabel }
        #expect(allLabelled)
    }

    @Test("#a carb label and a bolus label at the same spot don't both show")
    func carbAndBolusLabelsDontOverlap() {
        let treatments = [treatment(.bolus, minutesAgo: 10, label: "1.5"), treatment(.carbs, minutesAgo: 10, label: "30")]
        let drawn = WatchTreatmentHistory.drawn(treatments, insulinGap: 240, carbGap: 250, secondsPerLabelUnit: 300, mgdlPerLabelHeight: 20)
        let labelCount = drawn.filter { $0.showsLabel }.count
        #expect(labelCount == 1)
    }

    @Test("#separators and spaces count as narrow in label width")
    func labelWidths() {
        #expect(WatchTreatmentHistory.labelWidth(".2") == 1.5)
        #expect(WatchTreatmentHistory.labelWidth("1.25") == 3.5)
        #expect(WatchTreatmentHistory.labelWidth("30 3h") == 4.5)
    }

    @Test("#doses are labelled like the iPhone graph", arguments: [
        (0.2, ".2"), (0.05, ".05"), (1.5, "1.5"), (2.0, "2"), (12.35, "12.35"),
    ])
    func doseLabels(units: Double, expected: String) {
        #expect(WatchTreatmentHistory.doseLabel(units, locale: english) == expected)
    }

    @Test("#carbs show absorption hours only when set and enabled")
    func carbLabels() {
        #expect(WatchTreatmentHistory.carbLabel(grams: 30, absorptionMinutes: 180, showAbsorption: true) == "30 3h")
        #expect(WatchTreatmentHistory.carbLabel(grams: 30, absorptionMinutes: 0, showAbsorption: true) == "30")
        #expect(WatchTreatmentHistory.carbLabel(grams: 30, absorptionMinutes: 180, showAbsorption: false) == "30")
    }
}
