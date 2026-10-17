// LoopFollow
// WatchTreatmentHistory.swift

import Foundation

/// Recent boluses, SMBs and carbs sent to the Watch so its graph can mark them the
/// way the iPhone graph does.
struct WatchTreatmentHistory: Codable, Equatable {
    /// WatchConnectivity payload key.
    static let payloadKey = "treatments"
    /// Same span as the BG history the graph shows.
    static let window: TimeInterval = WatchGlucoseHistory.window

    enum Kind: String, Codable {
        case bolus
        case smb
        case carbs
    }

    struct Treatment: Codable, Equatable {
        let kind: Kind
        /// Treatment time, Unix epoch seconds.
        let date: TimeInterval
        /// Height to draw the marker at, in mg/dL — the iPhone graph's position, just above the BG line.
        let mgdl: Int
        /// Amount as the iPhone graph labels it, or "" when the phone hides values.
        let label: String

        private enum CodingKeys: String, CodingKey {
            case kind = "k"
            case date = "t"
            case mgdl = "g"
            case label = "l"
        }
    }

    /// When the phone built this history, Unix epoch seconds; an older history never replaces a newer one.
    let generatedAt: TimeInterval
    /// When the phone last downloaded treatments, Unix epoch seconds. Treatments after this
    /// are unknown, so the graph flags it once BG has moved well past it.
    let asOf: TimeInterval?
    /// Treatments inside the window, oldest first.
    let treatments: [Treatment]

    /// Builds a history from raw treatments, keeping only those inside `window` before `now`.
    static func make(from treatments: [Treatment], asOf: TimeInterval?, now: Date) -> WatchTreatmentHistory {
        let nowSeconds = now.timeIntervalSince1970
        let kept = treatments
            .filter { isInWindow($0.date, now: nowSeconds) }
            .sorted { $0.date < $1.date }
        return WatchTreatmentHistory(generatedAt: nowSeconds, asOf: asOf, treatments: kept)
    }

    /// Whether a treatment at `date` belongs in a history built at `now` (both Unix epoch seconds).
    static func isInWindow(_ date: TimeInterval, now: TimeInterval) -> Bool {
        date >= now - window && date <= now + 60
    }

    // MARK: - Graph layout

    /// A treatment, the time to draw it at (possibly a little left of its true time), and
    /// whether its amount label has room.
    struct Drawn {
        let treatment: Treatment
        let drawnDate: TimeInterval
        let showsLabel: Bool
    }

    /// Lays treatments out the way the iPhone graph does: boluses and SMBs share a height and
    /// symbol size so they are spread as one group, carbs on their own, each by up to its gap.
    /// A Watch graph has no room for every label, so labels that would overlap are left off:
    /// boluses and carbs claim room before SMBs, newer before older. `secondsPerLabelUnit` is
    /// how much graph time one digit of label text covers, `mgdlPerLabelHeight` how much of
    /// the BG axis one label line covers.
    static func drawn(
        _ treatments: [Treatment],
        insulinGap: TimeInterval,
        carbGap: TimeInterval,
        secondsPerLabelUnit: TimeInterval,
        mgdlPerLabelHeight: Double
    ) -> [Drawn] {
        func spread(_ group: [Treatment], gap: TimeInterval) -> [(treatment: Treatment, date: TimeInterval)] {
            let sorted = group.sorted { $0.date < $1.date }
            return zip(sorted, spreadDates(sorted.map(\.date), minGap: gap, maxShift: gap)).map { (treatment: $0, date: $1) }
        }
        let placed = spread(treatments.filter { $0.kind != .carbs }, gap: insulinGap)
            + spread(treatments.filter { $0.kind == .carbs }, gap: carbGap)
        // Labels are checked across both groups: a carb label can land right on a bolus label.
        let labelled = labelsThatFit(
            placed.map(\.treatment),
            at: placed.map(\.date),
            secondsPerLabelUnit: secondsPerLabelUnit,
            mgdlPerLabelHeight: mgdlPerLabelHeight
        )
        return placed.indices.map { Drawn(treatment: placed[$0].treatment, drawnDate: placed[$0].date, showsLabel: labelled.contains($0)) }
    }

    /// Indexes of the labels to show so that none overlap. Labels sit just above their
    /// markers, centered; two only clash when they are close both across and up the graph.
    /// Boluses and carbs come before SMBs, and newer treatments before older ones.
    static func labelsThatFit(
        _ treatments: [Treatment],
        at dates: [TimeInterval],
        secondsPerLabelUnit: TimeInterval,
        mgdlPerLabelHeight: Double
    ) -> Set<Int> {
        let margin = 0.5 * secondsPerLabelUnit
        let order = treatments.indices
            .filter { !treatments[$0].label.isEmpty }
            .sorted { a, b in
                let smbA = treatments[a].kind == .smb, smbB = treatments[b].kind == .smb
                return smbA != smbB ? !smbA : dates[a] > dates[b]
            }
        var shown: [Int] = []
        for i in order {
            let halfWidth = labelWidth(treatments[i].label) * secondsPerLabelUnit / 2
            let fits = shown.allSatisfy { j in
                let otherHalfWidth = labelWidth(treatments[j].label) * secondsPerLabelUnit / 2
                let apartAcross = abs(dates[i] - dates[j]) >= halfWidth + otherHalfWidth + margin
                let apartUp = Double(abs(treatments[i].mgdl - treatments[j].mgdl)) >= mgdlPerLabelHeight
                return apartAcross || apartUp
            }
            if fits { shown.append(i) }
        }
        return Set(shown)
    }

    /// Rough rendered width of a label in digit widths: separators and spaces are narrow.
    static func labelWidth(_ label: String) -> Double {
        label.reduce(0) { width, character in width + ("., ".contains(character) ? 0.5 : 1) }
    }

    /// The iPhone graph's declutter, on plain times. `dates` must be sorted ascending.
    /// Walking left from the newest, each time yields to its right neighbor until it hits
    /// its own left bound (`date - maxShift`); a run squeezed against its bounds is then
    /// re-spaced evenly up to the first time that still had room.
    static func spreadDates(_ dates: [TimeInterval], minGap: TimeInterval, maxShift: TimeInterval) -> [TimeInterval] {
        var drawn = dates
        guard drawn.count > 1 else { return drawn }

        var clamped = [Bool](repeating: false, count: drawn.count)
        for i in stride(from: drawn.count - 2, through: 0, by: -1) {
            let wanted = drawn[i + 1] - minGap
            guard drawn[i] > wanted else { continue }
            let leftBound = dates[i] - maxShift
            if wanted <= leftBound {
                drawn[i] = leftBound
                clamped[i] = true
            } else {
                drawn[i] = wanted
            }
        }

        var i = 0
        while i < drawn.count - 1 {
            guard clamped[i] else {
                i += 1
                continue
            }
            var last = i
            while clamped[last + 1] {
                last += 1
            }
            let anchorIndex = last + 1
            let anchor = drawn[anchorIndex]
            let leftBound = dates[i] - maxShift
            let spacing = (anchor - leftBound) / Double(anchorIndex - i)
            for k in i ... last {
                let ideal = anchor - spacing * Double(anchorIndex - k)
                drawn[k] = min(max(ideal, dates[k] - maxShift), dates[k])
            }
            i = anchorIndex + 1
        }
        return drawn
    }

    // MARK: - Labels

    private static func makeDoseFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = 0
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }

    /// Built once: the phone labels every treatment on each payload.
    private static let currentLocaleDoseFormatter = makeDoseFormatter(locale: .current)

    /// Insulin amount the way the iPhone graph writes it: up to two decimals, no leading zero (".2").
    static func doseLabel(_ units: Double, locale: Locale? = nil) -> String {
        let formatter = locale.map { makeDoseFormatter(locale: $0) } ?? currentLocaleDoseFormatter
        return formatter.string(from: NSNumber(value: units)) ?? String(units)
    }

    /// Carb amount the way the iPhone graph writes it: grams, plus absorption hours when shown ("30 3h").
    static func carbLabel(grams: Int, absorptionMinutes: Int, showAbsorption: Bool) -> String {
        guard absorptionMinutes > 0, showAbsorption else { return "\(grams)" }
        return "\(grams) \(absorptionMinutes / 60)h"
    }

    // MARK: - Encoding

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> WatchTreatmentHistory {
        try JSONDecoder().decode(WatchTreatmentHistory.self, from: data)
    }

    // MARK: - Persistence (Watch App Group)

    private static let key = "watch.treatmentHistory"

    func save() {
        guard let data = try? encoded() else { return }
        UserDefaults(suiteName: AppGroupID.current())?.set(data, forKey: Self.key)
    }

    static func load() -> WatchTreatmentHistory? {
        guard let data = UserDefaults(suiteName: AppGroupID.current())?.data(forKey: key) else { return nil }
        return try? decoded(from: data)
    }
}
