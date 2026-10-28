// LoopFollow
// WatchTreatmentList.swift

import Foundation

/// A row of the Watch's Treatments page, read from Nightscout's treatments by the rules the
/// phone's Treatments screen uses.
struct WatchTreatmentEntry: Equatable, Identifiable {
    enum Kind: String {
        case carbs
        case bolus
        /// A loop's automatic bolus.
        case automaticBolus
        case smb
        case tempBasal
        case override
        case tempTarget
    }

    let id: String
    let kind: Kind
    /// Unix epoch seconds.
    let date: TimeInterval
    /// The amount, e.g. "2.50 U", or the override's name.
    let title: String
    let subtitle: String
}

enum WatchTreatmentList {
    /// Treatments to ask Nightscout for at a time, as the phone does.
    static let pageSize = 100

    /// A page of Nightscout treatments as the Watch lists them.
    struct Page {
        /// Newest first.
        let entries: [WatchTreatmentEntry]
        /// The `_id`s of every treatment on the page, listed or not.
        let ids: Set<String>
        /// The oldest treatment on the page, listed or not; the next page ends there.
        let oldest: Date?
    }

    /// Rows from Nightscout `treatments.json` entries, newest first. A Meal Bolus gives a carbs row
    /// and a bolus row; an entry seen before (by its `_id`) is left out.
    static func entries(from json: [[String: Any]], unit: GlucoseSnapshot.Unit, skipping seen: Set<String> = []) -> [WatchTreatmentEntry] {
        page(from: json, unit: unit, skipping: seen).entries
    }

    static func page(from json: [[String: Any]], unit: GlucoseSnapshot.Unit, skipping seen: Set<String> = []) -> Page {
        var rows: [WatchTreatmentEntry] = []
        var seen = seen
        var ids = Set<String>()
        var oldest: Date?
        for entry in json {
            if let id = entry["_id"] as? String { ids.insert(id) }
            guard let createdAt = entry["created_at"] as? String, let date = parseDate(createdAt) else { continue }
            oldest = min(oldest ?? date, date)
            guard let eventType = entry["eventType"] as? String else { continue }
            let time = date.timeIntervalSince1970
            let id = entry["_id"] as? String ?? "\(eventType)-\(time)"
            guard seen.insert(id).inserted else { continue }

            func row(_ kind: WatchTreatmentEntry.Kind, _ title: String, _ subtitle: String) {
                rows.append(WatchTreatmentEntry(id: "\(id)-\(kind.rawValue)", kind: kind, date: time, title: title, subtitle: subtitle))
            }

            switch eventType {
            case "Carb Correction", "Meal Bolus":
                if let carbs = number(entry["carbs"]), carbs > 0 {
                    row(.carbs, "\(Int(carbs))g", "Carbs")
                }
                if eventType == "Meal Bolus", let insulin = number(entry["insulin"]), insulin > 0 {
                    row(.bolus, units(insulin), "Bolus")
                }

            case "Correction Bolus", "Bolus", "External Insulin":
                guard let insulin = number(entry["insulin"]), insulin > 0 else { continue }
                let isSMB = entry["isSMB"] as? Bool == true || (entry["type"] as? String)?.lowercased() == "smb"
                if isSMB {
                    row(.smb, units(insulin), "SMB")
                } else if entry["automatic"] as? Bool == true {
                    row(.automaticBolus, units(insulin), "Automatic Bolus")
                } else {
                    row(.bolus, units(insulin), "Bolus")
                }

            case "SMB":
                if let insulin = number(entry["insulin"]), insulin > 0 {
                    row(.smb, units(insulin), "SMB")
                }

            case "Temp Basal":
                if let rate = number(entry["rate"]) {
                    row(.tempBasal, String(format: "%.2f U/hr", rate), "Temp Basal")
                }

            case "Temporary Override", "Exercise":
                // An override with no duration is one being cancelled.
                guard let minutes = number(entry["duration"]), minutes != 0 else { continue }
                let name = text(entry["notes"]) ?? text(entry["reason"])
                row(.override, name ?? "Temporary Override", minutes > 0 ? "Override · \(Int(minutes))m" : "Override")

            case "Temporary Target":
                guard let minutes = number(entry["duration"]), minutes != 0 else { continue }
                let bottom = number(entry["targetBottom"]) ?? 0
                let top = number(entry["targetTop"]) ?? 0
                let target = bottom > 0 ? bottom : top
                guard target > 0 else { continue }
                let title = bottom > 0 && top > 0 && abs(top - bottom) >= 0.1
                    ? "\(glucose(bottom, unit)) - \(glucose(top, unit))"
                    : glucose(target, unit)
                let parts = ["Temp Target", minutes > 0 ? "\(Int(minutes))m" : nil, text(entry["reason"])]
                row(.tempTarget, title, parts.compactMap { $0 }.joined(separator: " · "))

            default:
                break
            }
        }
        return Page(entries: rows.sorted { $0.date > $1.date }, ids: ids, oldest: oldest)
    }

    /// Nightscout's `created_at`: ISO 8601, with or without fractional seconds and an offset.
    static func parseDate(_ string: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: string) { return date }
        }
        // No offset at all: Nightscout's times are UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // Booleans are NSNumbers too; they are never an amount.
            CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    private static func units(_ insulin: Double) -> String {
        String(format: "%.2f U", insulin)
    }

    private static func glucose(_ mgdl: Double, _ unit: GlucoseSnapshot.Unit) -> String {
        unit == .mmol ? String(format: "%.1f mmol/L", GlucoseConversion.toMmol(mgdl)) : "\(Int(mgdl.rounded())) mg/dL"
    }
}
