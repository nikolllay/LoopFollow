// LoopFollow
// AgeColoring.swift

import Foundation

/// The phone's Info Display coloring for an age such as CAGE, in days, so the Watch colors it
/// the same way. A level left unset never applies; below the levels that are set, it's green.
struct AgeColoring: Codable, Equatable {
    var warningDays: Double?
    var urgentDays: Double?

    enum Level: Equatable {
        case ok
        case warning
        case urgent
    }

    func level(forDays days: Double) -> Level {
        if let urgentDays, days >= urgentDays { return .urgent }
        if let warningDays, days >= warningDays { return .warning }
        return .ok
    }
}
