// LoopFollow
// WatchAlertManager.swift

import Foundation
import os.log
import UserNotifications
import WatchConnectivity

private let alertLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.loopfollow.watch",
    category: "WatchAlert"
)

extension Notification.Name {
    static let showSnoozeSheet = Notification.Name("WatchShowSnoozeSheet")
    /// An alarm started or ended, or was stopped or snoozed, or a snooze was cancelled.
    static let watchAlarmsChanged = Notification.Name("WatchAlarmsChanged")
}

// MARK: - Manager

/// Sounds the phone's alarms on the Watch. The phone decides every alarm from its own list and says
/// which one is sounding with each update; the Watch alerts for that one, repeating while the phone
/// repeats it, until it's snoozed or stopped here or on the phone, or the phone ends it. An alarm
/// the phone has turned off or snoozed never sounds here.
final class WatchAlertManager: NSObject {
    typealias Sounding = WatchAlarmState.Sounding

    static let shared = WatchAlertManager()

    override private init() {
        super.init()
        // Before any alarm can be posted, so its notification has its actions.
        registerNotificationCategories()
    }

    private let alertQueue = DispatchQueue(label: "com.loopfollow.watch.alertManager")
    /// App Group defaults — shared with main app target.
    private let defaults = UserDefaults(suiteName: AppGroupID.current()) ?? .standard

    private enum Key {
        /// The phone's latest alarm state, and when the phone sent it.
        static let state = "watchAlarmState"
        static let sentAt = "watchAlarmStateSentAt"
        /// The sounding last alerted for, kept once it's over, and when its first notification went out.
        static let alerted = "watchAlarmAlerted"
        static let alertedAt = "watchAlarmAlertedAt"
        /// The soundings answered here, newest last.
        static let answered = "watchAlarmAnswered"
    }

    // MARK: - Repeating

    /// An alarm keeps alerting until it's answered or the phone ends it, as the phone's sound
    /// repeats: its notification, and the tap with it, comes again this often.
    private static let repeatInterval: TimeInterval = 10
    /// How far past the phone's latest word the repeats run. The phone says what's sounding with
    /// every reading, so they go on for as long as the alarm is unanswered there, and stop soon
    /// after the phone goes quiet. watchOS keeps only an app's next 64 notifications, so this
    /// holds the repeats to 48.
    private static let repeatWindow: TimeInterval = 8 * 60
    /// Only one alarm sounds at a time, so the repeats have the same ids whichever it is.
    private static let repeatIDs = (1 ... Int(repeatWindow / repeatInterval)).map { "lf-alarm-r\($0)" }
    /// How many answered soundings are remembered, so a state the phone sent before it heard of
    /// the answer doesn't bring one back.
    private static let answeredLimit = 8

    /// The alarm's first notification: one id per alarm, so a new sounding of it replaces the last.
    private static func notificationID(for id: UUID) -> String {
        "lf-alarm-\(id.uuidString)"
    }

    // MARK: - Stored state, on alertQueue

    private var state: WatchAlarmState? {
        get { defaults.data(forKey: Key.state).flatMap { try? WatchAlarmState.decoded(from: $0) } }
        set { defaults.set(newValue.flatMap { try? $0.encoded() }, forKey: Key.state) }
    }

    private var sentAt: TimeInterval {
        get { defaults.double(forKey: Key.sentAt) }
        set { defaults.set(newValue, forKey: Key.sentAt) }
    }

    private var alerted: Sounding? {
        get { defaults.data(forKey: Key.alerted).flatMap { try? JSONDecoder().decode(Sounding.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.alerted) }
    }

    private var alertedAt: TimeInterval {
        get { defaults.double(forKey: Key.alertedAt) }
        set { defaults.set(newValue, forKey: Key.alertedAt) }
    }

    private var answered: [String] {
        get { defaults.stringArray(forKey: Key.answered) ?? [] }
        set { defaults.set(Array(newValue.suffix(Self.answeredLimit)), forKey: Key.answered) }
    }

    /// The latest reading that came with the phone's alarm state, which the notification shows
    /// before the store has it.
    private var reading: GlucoseSnapshot?

    /// The alarm sounding on the phone and unanswered here.
    private func soundingNow(at now: TimeInterval = Date().timeIntervalSince1970) -> Sounding? {
        state?.soundingToAlert(sentAt: sentAt, answered: answered, now: now)
    }

    // MARK: - Setup (call once from applicationDidFinishLaunching)

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        removeRetiredAlerts()
        // Sound, so an alarm can be heard like the phone's; a watch in silent mode still taps.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            os_log("WatchAlertManager: permission granted=%d", log: alertLog, type: .info, granted)
        }
    }

    /// Clears away the alerts the Watch raised itself before it mirrored the phone's: repeats still
    /// to come, and those already shown.
    private func removeRetiredAlerts() {
        let center = UNUserNotificationCenter.current()
        let isRetired: (String) -> Bool = { $0.hasPrefix("lf-alert-") }
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter(isRetired))
        }
        center.getDeliveredNotifications { notifications in
            center.removeDeliveredNotifications(withIdentifiers: notifications.map(\.request.identifier).filter(isRetired))
        }
    }

    // MARK: - Actions

    private enum Action {
        /// Snooze for the alarm's own length, as the phone's notification does.
        static let snooze = "ALARM_SNOOZE"
        /// Choose how long, on the snooze screen.
        static let chooseSnooze = "ALARM_SNOOZE_CHOOSE"
        /// Stop without a snooze, as the phone's Acknowledge does.
        static let stop = "ALARM_STOP"
    }

    /// An alarm's notification offers what the phone's snooze screen allows for it: a snooze of its
    /// own length unless that's 0, a choice of length when there is one, and Stop when it can be
    /// stopped without a snooze. There's a category for each mix.
    private static func category(snooze: Bool, choose: Bool, stop: Bool) -> String {
        "LF_ALARM_\(snooze ? "S" : "")\(choose ? "C" : "")\(stop ? "X" : "")"
    }

    private static func category(for sounding: Sounding) -> String {
        category(snooze: sounding.snoozesByDefault, choose: sounding.canChooseSnooze, stop: sounding.canAcknowledge)
    }

    private func registerNotificationCategories() {
        let snooze = UNNotificationAction(identifier: Action.snooze, title: "Snooze", options: [])
        let choose = UNNotificationAction(identifier: Action.chooseSnooze, title: "Snooze…", options: [.foreground])
        // Stops it now; it sounds again if the phone finds it still due.
        let stop = UNNotificationAction(identifier: Action.stop, title: "Stop", options: [])
        let flags = [false, true]
        var categories = Set<UNNotificationCategory>()
        for s in flags {
            for c in flags {
                for x in flags {
                    categories.insert(UNNotificationCategory(
                        identifier: Self.category(snooze: s, choose: c, stop: x),
                        actions: [s ? snooze : nil, c ? choose : nil, x ? stop : nil].compactMap { $0 },
                        intentIdentifiers: [],
                        options: []
                    ))
                }
            }
        }
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    // MARK: - From the phone

    /// Takes the phone's alarm state, sent at `sentAt` with `reading`: alerts for an alarm that has
    /// started sounding, keeps one still sounding repeating, and ends one the phone has ended. A
    /// state sent before the one already taken is ignored, as a late copy from a slower channel.
    func apply(_ incoming: WatchAlarmState, sentAt incomingSentAt: TimeInterval, reading incomingReading: GlucoseSnapshot? = nil) {
        let changed: Bool = alertQueue.sync {
            if let incomingReading, incomingReading.updatedAt > (reading?.updatedAt ?? .distantPast) {
                reading = incomingReading
            }
            // A time well ahead of this clock came from a phone clock that was later set back, and
            // must not hold off every state until real time catches up with it.
            let latest = sentAt <= Date().timeIntervalSince1970 + 300 ? sentAt : 0
            guard incomingSentAt >= latest else { return false }
            let before = (state, soundingNow())
            state = incoming
            sentAt = incomingSentAt
            update()
            return before.0 != incoming || before.1 != soundingNow()
        }
        if changed { notifyChanged() }
    }

    /// Brings the notifications in line with the phone's state: the alarm sounding there alerted for
    /// once, and repeating while the phone repeats it; the one alerted for before it, ended. Ended by
    /// a snooze on the phone, an alarm's notification is cleared away as answered; over by itself,
    /// it stays as a record. On `alertQueue`.
    private func update() {
        let now = Date().timeIntervalSince1970
        let center = UNUserNotificationCenter.current()
        let current = soundingNow(at: now)
        if let previous = alerted, previous.key != current?.key {
            center.removePendingNotificationRequests(withIdentifiers: Self.repeatIDs)
            center.removeDeliveredNotifications(withIdentifiers: Self.repeatIDs)
            if previous.id != current?.id, state?.snoozedUntil(previous.id, now: now) != nil {
                center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID(for: previous.id)])
            }
        }
        guard let current else { return }
        if current.key != alerted?.key {
            alerted = current
            alertedAt = now
            post(current)
        }
        scheduleRepeats(for: current, now: now)
    }

    /// The alarm's first notification, at once.
    private func post(_ sounding: Sounding) {
        let request = UNNotificationRequest(
            identifier: Self.notificationID(for: sounding.id),
            content: content(for: sounding),
            trigger: nil // immediate delivery
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                os_log("WatchAlertManager: failed %{public}@ — %{public}@",
                       log: alertLog, type: .error, sounding.name, error.localizedDescription)
            } else {
                os_log("WatchAlertManager: alerted %{public}@", log: alertLog, type: .info, sounding.name)
            }
        }
    }

    /// Schedules the repeats due before `repeatWindow` past the phone's latest word, every
    /// `repeatInterval` from the first notification, in place of those scheduled before; none while
    /// the phone isn't repeating its sound.
    private func scheduleRepeats(for sounding: Sounding, now: TimeInterval) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.repeatIDs)
        guard sounding.playsSound, sounding.repeats else { return }
        let end = min(sentAt, now) + Self.repeatWindow
        let content = content(for: sounding)
        // On the alarm's own beat, so word from the phone doesn't put the next repeat off.
        var next = alertedAt + Self.repeatInterval * ((max(0, now - alertedAt) / Self.repeatInterval).rounded(.down) + 1)
        for id in Self.repeatIDs {
            guard next <= end else { break }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, next - now), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            next += Self.repeatInterval
        }
    }

    /// An alarm's notification, the first and each repeat alike.
    private func content(for sounding: Sounding) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = sounding.name
        content.body = latestReading()
        content.sound = .default
        // Sounding out loud on the phone, it comes through a Focus here too.
        content.interruptionLevel = sounding.playsSound ? .timeSensitive : .active
        content.categoryIdentifier = Self.category(for: sounding)
        // Its repeats gather under it in Notification Center.
        content.threadIdentifier = Self.notificationID(for: sounding.id)
        // Which alarm it is, whichever of its notifications is answered.
        content.userInfo = ["alarmID": sounding.id.uuidString]
        return content
    }

    /// The latest reading, as the phone's alarm notification gives it: the one that came with the
    /// alarm, which the store can still be saving, or the one stored; nothing once it's too old to
    /// show. On `alertQueue`.
    private func latestReading() -> String {
        guard let s = [reading, GlucoseSnapshotStore.shared.load()].compactMap({ $0 }).max(by: { $0.updatedAt < $1.updatedAt }),
              s.updatedAt > Date(timeIntervalSinceNow: -15 * 60)
        else { return "" }
        return "\(WatchFormat.glucose(s)) \(WatchFormat.trendArrow(s)) \(WatchFormat.delta(s))"
    }

    // MARK: - Answering

    /// Snoozes the alarm on the phone for `units` of its snooze time, or its own length when nil, as
    /// the phone's snooze screen would; 0 stops it. It stops alerting here at once. `completion`
    /// runs once the snooze is on its way, on the main queue.
    /// Snoozes the alarm on the phone for `units` of its snooze time, or its own length when nil, as
    /// the phone's snooze screen would; 0 stops it. It stops alerting here at once. Once the Watch
    /// knows the sounding is over, the snooze only clears its notifications away: an older
    /// notification's Snooze answers nothing, as on the phone. `completion` runs once the snooze is
    /// on its way, on the main queue.
    func snooze(_ sounding: Sounding, units: Int?, completion: (() -> Void)? = nil) {
        let isSounding: Bool = alertQueue.sync {
            let isSounding = soundingNow()?.key == sounding.key
            answer(sounding)
            // Snoozed for the glucose page until the phone says so itself.
            let duration = sounding.snoozeDuration(units: units ?? sounding.snoozeUnits)
            if isSounding, duration > 0, var s = state {
                s.snoozes = s.snoozes.filter { $0.id != sounding.id }
                    + [WatchAlarmState.Snooze(id: sounding.id, until: Date().timeIntervalSince1970 + duration)]
                state = s
            }
            return isSounding
        }
        notifyChanged()
        guard isSounding else {
            DispatchQueue.main.async { completion?() }
            return
        }
        send(.snooze(Self.answer(to: sounding), units: units), completion: completion)
    }

    /// Stops the alarm on the phone without a snooze, as its Acknowledge does. It stops alerting here
    /// at once; once the Watch knows the sounding is over, the stop only clears its notifications
    /// away. `completion` runs once the stop is on its way, on the main queue.
    func stop(_ sounding: Sounding, completion: (() -> Void)? = nil) {
        let isSounding: Bool = alertQueue.sync {
            let isSounding = soundingNow()?.key == sounding.key
            answer(sounding)
            return isSounding
        }
        notifyChanged()
        guard isSounding else {
            DispatchQueue.main.async { completion?() }
            return
        }
        send(.stop(Self.answer(to: sounding)), completion: completion)
    }

    /// The answer to the sounding, given now.
    private static func answer(to sounding: Sounding) -> WatchAlarmCommand.Answer {
        WatchAlarmCommand.Answer(id: sounding.id, since: sounding.since, issuedAt: Date().timeIntervalSince1970)
    }

    /// The glucose page's Stop, for the alarm sounding, when it can be stopped without a snooze.
    func stopSounding() {
        guard let sounding = currentSounding(), sounding.canAcknowledge else { return }
        stop(sounding)
    }

    /// Ends the snoozes the glucose page shows, on the phone: Snooze All, and the snooze of the alarm
    /// that last sounded here.
    func cancelSnoozes() {
        let command: WatchAlarmCommand = alertQueue.sync {
            let id = alerted?.id
            let until = state?.snoozes.first { $0.id == id }?.until
            let allUntil = state?.snoozedAllUntil
            if var s = state {
                s.snoozedAllUntil = nil
                s.snoozes.removeAll { $0.id == id }
                state = s
            }
            // The snoozes as shown, so the phone ends those and no other set since.
            return .cancelSnoozes(id: id, until: until, allUntil: allUntil)
        }
        notifyChanged()
        send(command)
    }

    /// The sounding is answered here: it stops alerting, and its notifications are cleared away,
    /// unless a later sounding of the same alarm has taken them over, which the phone may still be
    /// sounding. On `alertQueue`.
    private func answer(_ sounding: Sounding) {
        answered = answered.filter { $0 != sounding.key } + [sounding.key]
        let center = UNUserNotificationCenter.current()
        if alerted?.key == sounding.key {
            center.removePendingNotificationRequests(withIdentifiers: Self.repeatIDs)
            center.removeDeliveredNotifications(withIdentifiers: Self.repeatIDs)
        }
        if alerted?.id != sounding.id || alerted?.key == sounding.key {
            center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID(for: sounding.id)])
        }
        os_log("WatchAlertManager: answered %{public}@", log: alertLog, type: .info, sounding.name)
    }

    /// Sends a command to the phone: at once when it can be reached, otherwise queued until it can.
    /// `completion` runs once it's handed to WatchConnectivity, on the main queue.
    private func send(_ command: WatchAlarmCommand, completion: (() -> Void)? = nil) {
        guard let data = try? command.encoded() else {
            DispatchQueue.main.async { completion?() }
            return
        }
        let message: [String: Any] = [WatchAlarmCommand.payloadKey: data]
        // A notification's action can launch the app before WatchConnectivity is ready.
        WatchSessionReceiver.shared.whenActivated { activated in
            defer { completion?() }
            guard activated else {
                os_log("WatchAlertManager: WatchConnectivity inactive, command not sent", log: alertLog, type: .error)
                return
            }
            let session = WCSession.default
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
            } else {
                session.transferUserInfo(message)
            }
        }
    }

    // MARK: - For the pages

    /// What the glucose page offers for the alarms.
    enum SnoozeStatus: Equatable {
        case none
        /// An alarm is sounding, unanswered: Snooze, and Stop when it can be stopped without one.
        case active(canStop: Bool)
        /// Alarms are snoozed until then: a Cancel button.
        case snoozed(until: Date)

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    func snoozeStatus() -> SnoozeStatus {
        alertQueue.sync {
            let now = Date().timeIntervalSince1970
            // A sounding alarm first, so it can always be snoozed or stopped.
            if let sounding = soundingNow(at: now) { return .active(canStop: sounding.canAcknowledge) }
            // Snooze All, or the snooze of the alarm that last sounded here, so it can be cancelled.
            if let until = state?.snoozedUntil(alerted?.id, now: now) {
                return .snoozed(until: Date(timeIntervalSince1970: until))
            }
            return .none
        }
    }

    /// The alarm sounding and unanswered, for the snooze screen.
    func currentSounding() -> Sounding? {
        alertQueue.sync { soundingNow() }
    }

    /// The alarm a notification is for, as it last sounded here, over or not, so a snooze from an
    /// older notification still reaches it.
    func sounding(for id: UUID) -> Sounding? {
        alertQueue.sync {
            if let current = soundingNow(), current.id == id { return current }
            return alerted?.id == id ? alerted : nil
        }
    }

    /// For the page: the alarms changed.
    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .watchAlarmsChanged, object: nil)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension WatchAlertManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let id = (response.notification.request.content.userInfo["alarmID"] as? String)
            .flatMap(UUID.init(uuidString:))
        else {
            completionHandler()
            return
        }
        // The phone decides whether an answer to an alarm that's over still counts; one from before
        // the alarm that last sounded here answers nothing, as on the phone.
        guard let sounding = sounding(for: id) else {
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case Action.snooze:
            snooze(sounding, units: nil, completion: completionHandler)

        case Action.stop:
            stop(sounding, completion: completionHandler)

        case Action.chooseSnooze:
            // Only while it's sounding: there's nothing left to snooze once it's over.
            if currentSounding()?.key == sounding.key {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .showSnoozeSheet,
                        object: nil,
                        userInfo: ["alarmID": id.uuidString]
                    )
                }
            }
            completionHandler()

        default:
            completionHandler()
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // With the app open, a banner alone shows for a moment and is gone with its Snooze and
        // Stop; the list keeps the alert in Notification Center until it's dealt with, and the
        // sound plays as it would with the app closed.
        completionHandler([.banner, .list, .sound, .badge])
    }
}
