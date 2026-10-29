// LoopFollow
// AlarmManager.swift

import Foundation
import UserNotifications

class AlarmManager {
    static let shared = AlarmManager()

    private let evaluators: [AlarmType: AlarmCondition]
    private var lastBGAlarmTime: Date?

    /// The alarm sounding, as the Watch mirrors it: when it started, and how its sound plays.
    struct Sounding: Equatable {
        let id: UUID
        let since: Date
        let playsSound: Bool
        let repeats: Bool
    }

    /// Set while `Observable.shared.currentAlarm` is. Main thread only.
    private(set) var sounding: Sounding?

    /// The sounding that ended last, and when, so a Watch answer given as it ended still counts.
    struct Ended: Equatable {
        let id: UUID
        let since: Date
        let at: Date
    }

    /// Main thread only.
    private var lastEnded: Ended?

    private init(
        conditionTypes: [AlarmCondition.Type] = [
            BuildExpireCondition.self,
            LowBGCondition.self,
            HighBGCondition.self,
            FastDropCondition.self,
            NotLoopingCondition.self,
            OverrideStartCondition.self,
            OverrideEndCondition.self,
            TempTargetStartCondition.self,
            TempTargetEndCondition.self,
            RecBolusCondition.self,
            COBCondition.self,
            MissedReadingCondition.self,
            FastRiseCondition.self,
            TemporaryCondition.self,
            SensorAgeCondition.self,
            PumpChangeCondition.self,
            PumpVolumeCondition.self,
            PumpBatteryCondition.self,
            IOBCondition.self,
            BatteryCondition.self,
            BatteryDropCondition.self,
            FutureCarbsCondition.self,
            DBSizeCondition.self,
        ]
    ) {
        var dict = [AlarmType: AlarmCondition]()
        conditionTypes.forEach { dict[$0.type] = $0.init() }
        evaluators = dict
    }

    func checkAlarms(data: AlarmData) {
        let now = Date()
        var alarmTriggered = false

        // No alarm activity while onboarding is on screen — existing or
        // QR-imported alarms shouldn't sound mid-setup.
        if Observable.shared.isOnboardingActive.value {
            if Observable.shared.currentAlarm.value != nil {
                stopAlarm()
            }
            return
        }

        let config = Storage.shared.alarmConfiguration.value

        // Honor the "Snooze All" setting. If active, stop any current alarm and exit.
        if let snoozeUntil = config.snoozeUntil, snoozeUntil > now {
            if Observable.shared.currentAlarm.value != nil {
                stopAlarm()
            }
            return
        }

        let alarms = Storage.shared.alarms.value

        let sorted = alarms.sorted(by: Alarm.byPriorityThenSpec)
        var skipType: AlarmType?

        let isLatestReadingRecent: Bool = {
            guard let last = data.bgReadings.last else { return false }
            return now.timeIntervalSince(last.date) <= 5 * 60
        }()

        for alarm in sorted {
            // If there is already an active (snoozed) alarm of this type, skip to next [type]
            if alarm.type == skipType {
                continue
            }

            // If an alarm is BG-based, it usually requires recent data.
            // We make a specific exception for .missedReading, whose entire
            // purpose is to fire when recent BG data is NOT recent.
            if alarm.type.isBGBased, alarm.type != .missedReading, !isLatestReadingRecent {
                continue
            }

            // If this is a bg-based alarm and we've already handled that same BG reading,
            // skip until we see a newer one.
            if alarm.type.isBGBased,
               let lastHandled = lastBGAlarmTime,
               let latestDate = data.bgReadings.last?.date,
               !(latestDate > lastHandled)
            {
                continue
            }

            // If the alarm itself is snoozed skip it, and skip lower‑priority alarms of the same type.
            // We still want other types af alarm to go off, so we continue here without breaking
            if let until = alarm.snoozedUntil, until > now {
                skipType = alarm.type
                continue
            }

            // Evaluate the alarm condition.
            guard let checker = evaluators[alarm.type],
                  checker
                  .shouldFire(
                      alarm: alarm,
                      data: data,
                      now: now,
                      config: Storage.shared.alarmConfiguration.value
                  )
            else {
                // If this alarm is active, but no longer fulfill the requirements, stop it.
                // Continue evaluating other alarams
                if Observable.shared.currentAlarm.value == alarm.id {
                    LogManager.shared.log(category: .alarm, message: "Stopping alarm \(alarm) because it no longer meets its requirements", isDebug: true)

                    stopAlarm()
                }

                continue
            }

            // If this alarm is active, and still fulfill the requirements, let it be active
            // Break the loop, nothing else to do
            if Observable.shared.currentAlarm.value == alarm.id {
                break
            }

            // Fire the alarm and break the loop; we only allow one alarm per evaluation tick.
            Observable.shared.currentAlarm.value = alarm.id

            let sound = alarm.trigger(config: Storage.shared.alarmConfiguration.value, now: now)
            // One it takes the place of has ended, as far as an answer from the Watch goes.
            if let sounding {
                lastEnded = Ended(id: sounding.id, since: sounding.since, at: now)
            }
            sounding = Sounding(id: alarm.id, since: now, playsSound: sound.playsSound, repeats: sound.repeats)

            // Store the latest bg time so we don't use it again
            if alarm.type.isBGBased,
               let latestDate = data.bgReadings.last?.date
            {
                lastBGAlarmTime = latestDate
            }

            if alarm.type == .temporary {
                // turn it off and persist
                var list = Storage.shared.alarms.value
                if let idx = list.firstIndex(where: { $0.id == alarm.id }) {
                    list[idx].isEnabled = false
                    list[idx].snoozedUntil = nil
                    Storage.shared.alarms.value = list
                }
            }

            alarmTriggered = true
            break
        }

        if isLatestReadingRecent, Storage.shared.persistentNotification.value, !alarmTriggered, let latestDate = data.bgReadings.last?.date, latestDate > Storage.shared.persistentNotificationLastBGTime.value {
            sendNotification(title: "Latest BG")
            Storage.shared.persistentNotificationLastBGTime.value = now
        }
    }

    func performSnooze(_ snoozeUnits: Int? = nil) {
        guard let alarmID = Observable.shared.currentAlarm.value else { return }
        var alarms = Storage.shared.alarms.value
        if let idx = alarms.firstIndex(where: { $0.id == alarmID }) {
            let alarm = alarms[idx]
            let units = snoozeUnits ?? alarm.snoozeDuration
            if units > 0 {
                let snoozeSeconds = Double(units) * alarm.type.snoozeTimeUnit.seconds
                alarms[idx].snoozedUntil = Date().addingTimeInterval(snoozeSeconds)
                Storage.shared.alarms.value = alarms
            }
            Observable.shared.alarmSoundPlaying.value = false
            stopAlarm()
        }
    }

    func stopAlarm() {
        AlarmSound.stop()
        if let sounding {
            lastEnded = Ended(id: sounding.id, since: sounding.since, at: Date())
        }
        sounding = nil
        Observable.shared.currentAlarm.value = nil
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: - From the Watch

    /// What a snooze or stop from the Watch reaches.
    enum AnswerTarget: Equatable {
        /// The sounding it answers, still sounding.
        case sounding
        /// The alarm, whose sounding ended just as the answer was given, before the Watch heard.
        case endedAlarm
        /// Nothing: an answer to a sounding long over, or one that arrived late from a Watch that was
        /// out of reach, as the Snooze on an older notification on the phone does nothing.
        case none
    }

    static func target(of answer: WatchAlarmCommand.Answer, sounding: Sounding?, lastEnded: Ended?, now: Date) -> AnswerTarget {
        func isAnswered(_ id: UUID, since: Date) -> Bool {
            id == answer.id && abs(since.timeIntervalSince1970 - answer.since) < 0.001
        }
        if let sounding, isAnswered(sounding.id, since: sounding.since) { return .sounding }
        let issued = Date(timeIntervalSince1970: answer.issuedAt)
        guard now.timeIntervalSince(issued) <= WatchAlarmCommand.answerGrace,
              let lastEnded, isAnswered(lastEnded.id, since: lastEnded.since),
              issued.timeIntervalSince(lastEnded.at) <= WatchAlarmCommand.answerGrace
        else { return .none }
        return .endedAlarm
    }

    /// Until when a Watch snooze keeps an alarm quiet that's no longer sounding: `units` of its
    /// snooze time from when the snooze was given. Nil when that has passed, or isn't later than
    /// the snooze the alarm has, which it never shortens.
    static func snoozedUntil(issuedAt: TimeInterval, units: Int, unitSeconds: TimeInterval, current: Date?, now: Date) -> Date? {
        let until = Date(timeIntervalSince1970: issuedAt).addingTimeInterval(Double(units) * unitSeconds)
        guard until > now, until > (current ?? .distantPast) else { return nil }
        return until
    }

    /// Snoozes the alarm from the Watch for `units` of its snooze time, kept to what its snooze
    /// screen offers, or for its own length when nil. The sounding answered stops, as does one of the
    /// same alarm that started just after it, before the Watch heard; an alarm whose sounding ended
    /// just as the snooze was given is kept quiet for that long. Anything else is left alone.
    /// Main thread only.
    func snooze(_ answer: WatchAlarmCommand.Answer, units: Int?) {
        let now = Date()
        var alarms = Storage.shared.alarms.value
        guard Self.target(of: answer, sounding: sounding, lastEnded: lastEnded, now: now) != .none,
              let idx = alarms.firstIndex(where: { $0.id == answer.id })
        else {
            LogManager.shared.log(category: .alarm, message: "Watch snooze of an alarm no longer sounding, ignored")
            return
        }
        let type = alarms[idx].type
        let units = min(max(units ?? alarms[idx].snoozeDuration, type.snoozeRange.lowerBound), type.snoozeRange.upperBound)
        if Observable.shared.currentAlarm.value == answer.id {
            performSnooze(units)
        } else if let until = Self.snoozedUntil(
            issuedAt: answer.issuedAt,
            units: units,
            unitSeconds: type.snoozeTimeUnit.seconds,
            current: alarms[idx].snoozedUntil,
            now: now
        ) {
            alarms[idx].snoozedUntil = until
            Storage.shared.alarms.value = alarms
        }
    }

    /// Stops the alarm from the Watch without a snooze, as Acknowledge does: the sounding answered,
    /// or one of the same alarm that started just after it, before the Watch heard. Main thread only.
    func stop(_ answer: WatchAlarmCommand.Answer) {
        guard Self.target(of: answer, sounding: sounding, lastEnded: lastEnded, now: Date()) != .none,
              Observable.shared.currentAlarm.value == answer.id
        else {
            LogManager.shared.log(category: .alarm, message: "Watch stop of an alarm no longer sounding, ignored")
            return
        }
        performSnooze(0)
    }

    /// Whether a snooze is still the one the Watch showed, ending at `shown`. A minute either way
    /// allows for a snooze the Watch set itself and showed before the phone's own time for it came.
    static func isSameSnooze(_ current: Date?, as shown: TimeInterval?) -> Bool {
        guard let current, let shown else { return false }
        return abs(current.timeIntervalSince1970 - shown) <= 60
    }

    /// Ends the snoozes the Watch showed, the alarm's own and Snooze All, while they're still those
    /// it showed, however late the request arrives; a snooze set since stands. Main thread only.
    func cancelSnoozes(alarmID: UUID?, until: TimeInterval?, allUntil: TimeInterval?) {
        var alarms = Storage.shared.alarms.value
        if let idx = alarms.firstIndex(where: { $0.id == alarmID }), Self.isSameSnooze(alarms[idx].snoozedUntil, as: until) {
            alarms[idx].snoozedUntil = nil
            Storage.shared.alarms.value = alarms
        }
        var config = Storage.shared.alarmConfiguration.value
        if Self.isSameSnooze(config.snoozeUntil, as: allUntil) {
            config.snoozeUntil = nil
            Storage.shared.alarmConfiguration.value = config
        }
    }

    func sendNotification(title: String, actionTitle: String? = nil) {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle += Observable.shared.bgText.value + " "
        content.subtitle += Observable.shared.directionText.value + " "
        content.subtitle += Observable.shared.deltaText.value
        content.categoryIdentifier = "category"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

        if let actionTitle = actionTitle {
            let action = UNNotificationAction(identifier: "snooze", title: actionTitle, options: [])
            let category = UNNotificationCategory(identifier: "category", actions: [action], intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories([category])
        }
    }
}
