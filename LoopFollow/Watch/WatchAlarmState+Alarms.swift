// LoopFollow
// WatchAlarmState+Alarms.swift

import Foundation

extension WatchAlarmState {
    /// The phone's alarms for the Watch: the one sounding, while it's still the current alarm;
    /// Snooze All while it runs; and the alarms that are on and snoozed on their own.
    static func make(
        alarms: [Alarm],
        config: AlarmConfiguration,
        sounding: AlarmManager.Sounding?,
        currentAlarm: UUID?,
        now: Date
    ) -> WatchAlarmState {
        var state = WatchAlarmState()
        if let sounding, sounding.id == currentAlarm,
           let alarm = alarms.first(where: { $0.id == sounding.id })
        {
            state.sounding = Sounding(
                id: alarm.id,
                since: sounding.since.timeIntervalSince1970,
                name: alarm.name,
                playsSound: sounding.playsSound,
                repeats: sounding.repeats,
                snoozeUnits: alarm.snoozeDuration,
                snoozeRange: alarm.type.snoozeRange,
                snoozeStep: alarm.type.snoozeStep,
                snoozeUnitSeconds: alarm.type.snoozeTimeUnit.seconds
            )
        }
        if let until = config.snoozeUntil, until > now {
            state.snoozedAllUntil = until.timeIntervalSince1970
        }
        state.snoozes = alarms.compactMap { alarm in
            guard alarm.isEnabled, let until = alarm.snoozedUntil, until > now else { return nil }
            return Snooze(id: alarm.id, until: until.timeIntervalSince1970)
        }
        return state
    }
}
