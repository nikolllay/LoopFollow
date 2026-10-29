// LoopFollow
// WatchAlarmState.swift

import Foundation

/// The phone's alarms, which the Watch mirrors. The phone decides every alarm from its own list,
/// so the Watch sounds only the alarm the phone is sounding: never one turned off or snoozed there.
/// A snooze or stop on the Watch goes back to the phone, as the phone's own would.
struct WatchAlarmState: Codable, Equatable {
    /// WatchConnectivity payload key.
    static let payloadKey = "alarms"
    /// When the phone sent the state. A key of its own, so the same state sent twice is equal.
    static let sentAtKey = "alarmsSentAt"
    /// How long the Watch takes the phone's word that an alarm is sounding: longer than the 15
    /// minutes the phone leaves between sends of unchanged state, so a phone gone quiet can't leave
    /// an alarm sounding on the Watch.
    static let soundingTimeout: TimeInterval = 20 * 60

    /// The alarm sounding on the phone, with the snooze its snooze screen offers.
    struct Sounding: Codable, Equatable {
        /// The phone alarm's id.
        var id: UUID
        /// When it started sounding. The same alarm sounding again later is a new sounding.
        var since: TimeInterval
        /// Its name on the phone, such as "Urgent low".
        var name: String
        /// Whether the phone plays its sound; muted, or outside its sound hours, it only notifies.
        var playsSound: Bool
        /// Whether the phone repeats its sound until it's answered.
        var repeats: Bool
        /// Its own snooze length, in snooze units; 0 stops it without a snooze.
        var snoozeUnits: Int
        /// The snooze lengths the phone offers for it, in snooze units, from 0 when it can be
        /// stopped without one; and the step between them.
        var snoozeRange: ClosedRange<Int>
        var snoozeStep: Int
        /// Seconds in a snooze unit, a minute, hour or day; 0 when it can't be snoozed.
        var snoozeUnitSeconds: TimeInterval
    }

    /// An alarm snoozed on its own, until then.
    struct Snooze: Codable, Equatable {
        var id: UUID
        var until: TimeInterval
    }

    /// The alarm sounding on the phone, if one is.
    var sounding: Sounding?
    /// Until when every alarm is snoozed, by the phone's Snooze All.
    var snoozedAllUntil: TimeInterval?
    /// The alarms that are on and snoozed on their own.
    var snoozes: [Snooze] = []

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> WatchAlarmState {
        try JSONDecoder().decode(WatchAlarmState.self, from: data)
    }

    /// The sounding to alert for, in a state the phone sent at `sentAt`: none once it's answered on
    /// the Watch, by the keys of the soundings answered, or once the phone has said nothing for
    /// longer than `soundingTimeout`.
    func soundingToAlert(sentAt: TimeInterval, answered: [String], now: TimeInterval) -> Sounding? {
        guard let sounding, now - sentAt < Self.soundingTimeout, !answered.contains(sounding.key) else { return nil }
        return sounding
    }

    /// Until when the alarm can't sound: the later of its own snooze and Snooze All; nil while
    /// neither runs.
    func snoozedUntil(_ id: UUID?, now: TimeInterval) -> TimeInterval? {
        let own = snoozes.first { $0.id == id }?.until
        return [own, snoozedAllUntil].compactMap { $0 }.filter { $0 > now }.max()
    }
}

extension WatchAlarmState.Sounding {
    /// Which sounding it is: the alarm, and when it started.
    var key: String {
        "\(id.uuidString)@\(since)"
    }

    /// It can be stopped without a snooze, as the phone's Acknowledge does. One that would only
    /// sound again at once, such as Not Looping, can't.
    var canAcknowledge: Bool {
        snoozeRange.lowerBound == 0
    }

    /// A snooze of its own length snoozes it; at 0 it only stops it.
    var snoozesByDefault: Bool {
        snoozeUnits > 0 && snoozeUnitSeconds > 0
    }

    /// There's a choice of how long to snooze it.
    var canChooseSnooze: Bool {
        snoozeUnitSeconds > 0 && snoozeRange.upperBound > snoozeRange.lowerBound
    }

    /// How long `units` of its snooze last.
    func snoozeDuration(units: Int) -> TimeInterval {
        Double(units) * snoozeUnitSeconds
    }
}

/// A snooze, stop or cancelled snooze from the Watch, which the phone carries out on its alarms.
enum WatchAlarmCommand: Codable, Equatable {
    /// Snooze the alarm for this many of its snooze units, or for its own length when nil, as the
    /// phone's snooze screen does; 0 stops it without a snooze.
    case snooze(Answer, units: Int?)
    /// Stop the alarm without a snooze, as the phone's Acknowledge does.
    case stop(Answer)
    /// End the snoozes the Watch showed, until then: the alarm's own and Snooze All, so alarms can
    /// sound again. Each ends only while it's still the one the Watch showed.
    case cancelSnoozes(id: UUID?, until: TimeInterval?, allUntil: TimeInterval?)

    /// The sounding a snooze or stop answers, and when it was given on the Watch, so the phone
    /// can tell an answer to the alarm sounding from a late one that must answer nothing else.
    struct Answer: Codable, Equatable {
        var id: UUID
        var since: TimeInterval
        var issuedAt: TimeInterval
    }

    /// How long an answer to a sounding that has ended stays good: one given just as it ended,
    /// before the Watch heard, still keeps that alarm quiet; one that reaches the phone later, from
    /// a Watch that was out of reach, answers nothing else.
    static let answerGrace: TimeInterval = 2 * 60

    /// WatchConnectivity message key.
    static let payloadKey = "watchAlarmCommand"

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> WatchAlarmCommand {
        try JSONDecoder().decode(WatchAlarmCommand.self, from: data)
    }
}
