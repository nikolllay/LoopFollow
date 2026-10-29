// LoopFollow
// WatchAlarmStateTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct WatchAlarmStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var t: TimeInterval { now.timeIntervalSince1970 }

    private func alarm(_ type: AlarmType, name: String? = nil, enabled: Bool = true, snoozedForMinutes minutes: Double? = nil) -> Alarm {
        var alarm = Alarm(type: type)
        if let name { alarm.name = name }
        alarm.isEnabled = enabled
        alarm.snoozedUntil = minutes.map { now.addingTimeInterval($0 * 60) }
        return alarm
    }

    private func sounding(_ alarm: Alarm, playsSound: Bool = true, repeats: Bool = true) -> AlarmManager.Sounding {
        AlarmManager.Sounding(id: alarm.id, since: now.addingTimeInterval(-60), playsSound: playsSound, repeats: repeats)
    }

    private func mirror(_ alarms: [Alarm], sounding: AlarmManager.Sounding? = nil, current: UUID? = nil, config: AlarmConfiguration = .default) -> WatchAlarmState {
        WatchAlarmState.make(alarms: alarms, config: config, sounding: sounding, currentAlarm: current, now: now)
    }

    // MARK: - From the phone's alarms

    @Test("#nothing sounds on the Watch while nothing sounds on the phone")
    func nothingSounding() {
        #expect(mirror([alarm(.low), alarm(.fastRise)]).sounding == nil)
    }

    @Test("#the alarm sounding on the phone is mirrored with its name and snooze")
    func soundingMirrored() throws {
        var urgentLow = alarm(.low, name: "Urgent low")
        urgentLow.snoozeDuration = 15
        let mirrored = try #require(mirror([urgentLow], sounding: sounding(urgentLow, repeats: false), current: urgentLow.id).sounding)
        #expect(mirrored.id == urgentLow.id)
        #expect(mirrored.name == "Urgent low")
        #expect(mirrored.since == t - 60)
        #expect(mirrored.playsSound)
        #expect(!mirrored.repeats)
        #expect(mirrored.snoozeUnits == 15)
        #expect(mirrored.snoozeRange == AlarmType.low.snoozeRange)
        #expect(mirrored.snoozeStep == AlarmType.low.snoozeStep)
        #expect(mirrored.snoozeDuration(units: 15) == 15 * 60)
        #expect(mirrored.canAcknowledge)
        #expect(mirrored.snoozesByDefault)
        #expect(mirrored.canChooseSnooze)
    }

    @Test("#a sounding that is no longer the phone's current alarm isn't mirrored")
    func endedSounding() {
        let low = alarm(.low)
        #expect(mirror([low], sounding: sounding(low), current: nil).sounding == nil)
        #expect(mirror([low], sounding: sounding(low), current: UUID()).sounding == nil)
    }

    @Test("#an alarm that would only sound again at once can't be stopped without a snooze")
    func notLoopingOnlySnoozes() throws {
        let notLooping = alarm(.notLooping)
        let mirrored = try #require(mirror([notLooping], sounding: sounding(notLooping), current: notLooping.id).sounding)
        #expect(!mirrored.canAcknowledge)
        #expect(mirrored.snoozesByDefault)
    }

    @Test("#a one-time alarm can only be stopped")
    func temporaryOnlyStops() throws {
        let temporary = alarm(.temporary)
        let mirrored = try #require(mirror([temporary], sounding: sounding(temporary), current: temporary.id).sounding)
        #expect(mirrored.canAcknowledge)
        #expect(!mirrored.snoozesByDefault)
        #expect(!mirrored.canChooseSnooze)
    }

    @Test("#only alarms that are on and still snoozed go as snoozed")
    func snoozes() {
        let snoozed = alarm(.high, snoozedForMinutes: 30)
        let expired = alarm(.fastDrop, snoozedForMinutes: -1)
        let off = alarm(.low, enabled: false, snoozedForMinutes: 30)
        #expect(mirror([snoozed, expired, off]).snoozes == [WatchAlarmState.Snooze(id: snoozed.id, until: t + 30 * 60)])
    }

    @Test("#Snooze All goes only while it runs")
    func snoozeAll() {
        var config = AlarmConfiguration.default
        config.snoozeUntil = now.addingTimeInterval(3600)
        #expect(mirror([], config: config).snoozedAllUntil == t + 3600)
        config.snoozeUntil = now.addingTimeInterval(-1)
        #expect(mirror([], config: config).snoozedAllUntil == nil)
    }

    // MARK: - On the Watch

    @Test("#the Watch alerts for the sounding until it's answered there or the phone goes quiet")
    func soundingToAlert() throws {
        let low = alarm(.low)
        let state = mirror([low], sounding: sounding(low), current: low.id)
        let mirrored = try #require(state.sounding)
        #expect(state.soundingToAlert(sentAt: t, answered: [], now: t) == mirrored)
        #expect(state.soundingToAlert(sentAt: t, answered: [mirrored.key], now: t) == nil)
        #expect(state.soundingToAlert(sentAt: t - WatchAlarmState.soundingTimeout + 1, answered: [], now: t) == mirrored)
        #expect(state.soundingToAlert(sentAt: t - WatchAlarmState.soundingTimeout, answered: [], now: t) == nil)
    }

    @Test("#an answered alarm that sounds again alerts again")
    func newSoundingAlerts() {
        let first = WatchAlarmState.Sounding(
            id: UUID(), since: t - 600, name: "Low", playsSound: true, repeats: true,
            snoozeUnits: 5, snoozeRange: 0 ... 120, snoozeStep: 5, snoozeUnitSeconds: 60
        )
        var again = first
        again.since = t
        #expect(first.key != again.key)
        let state = WatchAlarmState(sounding: again)
        #expect(state.soundingToAlert(sentAt: t, answered: [first.key], now: t) == again)
    }

    @Test("#an alarm can't sound until the later of its own snooze and Snooze All")
    func snoozedUntil() {
        let id = UUID()
        var state = WatchAlarmState(snoozedAllUntil: t + 600, snoozes: [.init(id: id, until: t + 1200)])
        #expect(state.snoozedUntil(id, now: t) == t + 1200)
        #expect(state.snoozedUntil(UUID(), now: t) == t + 600)
        #expect(state.snoozedUntil(nil, now: t) == t + 600)
        #expect(state.snoozedUntil(id, now: t + 1200) == nil)
        state.snoozedAllUntil = nil
        #expect(state.snoozedUntil(nil, now: t) == nil)
    }

    // MARK: - Over WatchConnectivity

    @Test("#the state survives the WatchConnectivity encoding")
    func stateRoundTrip() throws {
        let low = alarm(.low, name: "Urgent low")
        var config = AlarmConfiguration.default
        config.snoozeUntil = now.addingTimeInterval(900)
        let state = mirror([low, alarm(.high, snoozedForMinutes: 45)], sounding: sounding(low), current: low.id, config: config)
        #expect(try WatchAlarmState.decoded(from: state.encoded()) == state)
    }

    @Test("#commands survive the WatchConnectivity encoding")
    func commandRoundTrip() throws {
        let answer = WatchAlarmCommand.Answer(id: UUID(), since: t - 60, issuedAt: t)
        let commands: [WatchAlarmCommand] = [
            .snooze(answer, units: 30),
            .snooze(answer, units: nil),
            .stop(answer),
            .cancelSnoozes(id: UUID(), until: t + 600, allUntil: nil),
            .cancelSnoozes(id: nil, until: nil, allUntil: t + 3600),
        ]
        for command in commands {
            #expect(try WatchAlarmCommand.decoded(from: command.encoded()) == command)
        }
    }

    // MARK: - Answers from the Watch, on the phone

    private let alarmID = UUID()
    private var since: Date { now.addingTimeInterval(-300) }

    private func answer(issuedSecondsAgo: TimeInterval, since: Date? = nil) -> WatchAlarmCommand.Answer {
        WatchAlarmCommand.Answer(id: alarmID, since: (since ?? self.since).timeIntervalSince1970, issuedAt: t - issuedSecondsAgo)
    }

    private func soundingNow(since: Date? = nil) -> AlarmManager.Sounding {
        AlarmManager.Sounding(id: alarmID, since: since ?? self.since, playsSound: true, repeats: true)
    }

    @Test("#an answer reaches the sounding it answers while that's still sounding, however late it arrives")
    func answerReachesSounding() {
        let target = AlarmManager.target(of: answer(issuedSecondsAgo: 3600), sounding: soundingNow(), lastEnded: nil, now: now)
        #expect(target == .sounding)
    }

    @Test("#a late answer doesn't reach a newer sounding of the same alarm")
    func lateAnswerSkipsNewSounding() {
        let newer = soundingNow(since: now.addingTimeInterval(-30))
        let ended = AlarmManager.Ended(id: alarmID, since: since, at: now.addingTimeInterval(-60))
        let late = answer(issuedSecondsAgo: WatchAlarmCommand.answerGrace + 1)
        #expect(AlarmManager.target(of: late, sounding: newer, lastEnded: ended, now: now) == .none)
    }

    @Test("#an answer given just as its sounding ended still keeps the alarm quiet")
    func answerAsSoundingEnded() {
        let ended = AlarmManager.Ended(id: alarmID, since: since, at: now.addingTimeInterval(-10))
        #expect(AlarmManager.target(of: answer(issuedSecondsAgo: 5), sounding: nil, lastEnded: ended, now: now) == .endedAlarm)
    }

    @Test("#an answer to a sounding long over, such as an old notification's, answers nothing")
    func answerToOldSounding() {
        let ended = AlarmManager.Ended(id: alarmID, since: since, at: now.addingTimeInterval(-3600))
        #expect(AlarmManager.target(of: answer(issuedSecondsAgo: 1), sounding: nil, lastEnded: ended, now: now) == .none)
        #expect(AlarmManager.target(of: answer(issuedSecondsAgo: 1), sounding: nil, lastEnded: nil, now: now) == .none)
    }

    @Test("#an answer for another alarm's sounding reaches nothing")
    func answerToOtherAlarm() {
        let other = AlarmManager.Sounding(id: UUID(), since: since, playsSound: true, repeats: true)
        #expect(AlarmManager.target(of: answer(issuedSecondsAgo: 1), sounding: other, lastEnded: nil, now: now) == .none)
    }

    @Test("#a cancel from the Watch ends the snooze it showed, however late, and no other set since")
    func cancelEndsSnoozeShown() {
        let shown = t + 1800
        #expect(AlarmManager.isSameSnooze(Date(timeIntervalSince1970: shown), as: shown))
        // The Watch's own snooze, shown before the phone's time for it came.
        #expect(AlarmManager.isSameSnooze(Date(timeIntervalSince1970: shown + 20), as: shown))
        // Set again since, with another end.
        #expect(!AlarmManager.isSameSnooze(Date(timeIntervalSince1970: shown + 3600), as: shown))
        #expect(!AlarmManager.isSameSnooze(nil, as: shown))
        #expect(!AlarmManager.isSameSnooze(Date(timeIntervalSince1970: shown), as: nil))
    }

    @Test("#a snooze of an alarm that's over runs from when it was given, and never shortens a longer one")
    func snoozeOfEndedAlarm() {
        let issued = t - 30
        #expect(AlarmManager.snoozedUntil(issuedAt: issued, units: 5, unitSeconds: 60, current: nil, now: now)
            == Date(timeIntervalSince1970: issued + 300))
        #expect(AlarmManager.snoozedUntil(issuedAt: issued, units: 5, unitSeconds: 60, current: now.addingTimeInterval(3600), now: now) == nil)
        #expect(AlarmManager.snoozedUntil(issuedAt: issued, units: 0, unitSeconds: 60, current: nil, now: now) == nil)
    }
}
