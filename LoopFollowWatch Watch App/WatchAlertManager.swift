// LoopFollow
// WatchAlertManager.swift

import Foundation
import os.log
import UserNotifications

private let alertLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.loopfollow.watch",
    category: "WatchAlert"
)

extension Notification.Name {
    static let showSnoozeSheet = Notification.Name("WatchShowSnoozeSheet")
    /// An alarm started or ended, or was stopped or snoozed, or a snooze was cancelled.
    static let watchAlarmsChanged = Notification.Name("WatchAlarmsChanged")
}

// MARK: - Alert type

enum WatchAlertType: String, CaseIterable {
    case lowBG, urgentLow, highBG, fastDrop, fastRise

    var title: String {
        switch self {
        case .lowBG: return "⚠️ Low BG"
        case .urgentLow: return "🚨 Urgent Low"
        case .highBG: return "⚠️ High BG"
        case .fastDrop: return "⬇️ Dropping Fast"
        case .fastRise: return "⬆️ Rising Fast"
        }
    }

    var displayName: String {
        switch self {
        case .lowBG: return "Low BG"
        case .urgentLow: return "Urgent Low"
        case .highBG: return "High BG"
        case .fastDrop: return "Fast Drop"
        case .fastRise: return "Fast Rise"
        }
    }

    func body(bg: Double, delta: Double?) -> String {
        let bgStr = "\(Int(bg))"
        switch self {
        case .lowBG, .urgentLow, .highBG: return bgStr
        case .fastDrop: return delta.map { "\(bgStr) · \(Int($0))/min" } ?? bgStr
        case .fastRise: return delta.map { "\(bgStr) · +\(Int($0))/min" } ?? bgStr
        }
    }

    var cooldownKey: String { "watchAlertCooldown_\(rawValue)" }
    var snoozeKey: String { "watchSnoozeUntil_\(rawValue)" }
    var notificationID: String { "lf-alert-\(rawValue)" }
}

// MARK: - Thresholds

private struct WatchThresholds {
    var low: Double
    var urgentLow: Double
    var high: Double
    var dropRate: Double = 2.0 // mg/dL per minute
    var riseRate: Double = 2.0

    /// Low/high follow the iPhone's BG lines, synced into the Watch App Group.
    /// Urgent low stays at 55 mg/dL unless the low line is set below that.
    static func current() -> WatchThresholds {
        let lines = LAAppGroupSettings.thresholdsMgdl()
        return WatchThresholds(low: lines.low, urgentLow: min(55, lines.low), high: lines.high)
    }
}

// MARK: - Manager

final class WatchAlertManager: NSObject {
    static let shared = WatchAlertManager()
    override private init() { super.init() }

    private var thresholds: WatchThresholds { WatchThresholds.current() }
    private let settings = WatchAppSettings.shared
    private let alertQueue = DispatchQueue(label: "com.loopfollow.watch.alertManager")

    private let globalSnoozeKey = "watchGlobalSnoozeUntil"

    // MARK: - Repeating

    /// An alarm keeps alerting until it's snoozed or stopped, or its threshold is no longer met,
    /// like the phone's: its notification comes again this often.
    private static let repeatInterval: TimeInterval = 30
    /// How far ahead the repeats are scheduled. Each reading, every 5 minutes, schedules the
    /// next stretch, so they go on for as long as the alarm is unanswered.
    private static let repeatWindow: TimeInterval = 10 * 60
    private static var repeatCount: Int { Int(repeatWindow / repeatInterval) }
    /// Only the most urgent unanswered alarm repeats, so two never sound together.
    private static let repeatPriority: [WatchAlertType] = [.urgentLow, .lowBG, .fastDrop, .highBG, .fastRise]

    /// Whether the alarm has fired and is still unanswered.
    private func isOpen(_ type: WatchAlertType) -> Bool {
        defaults.bool(forKey: "watchAlarmOpen_\(type.rawValue)")
    }

    private func setOpen(_ type: WatchAlertType, _ open: Bool) {
        defaults.set(open, forKey: "watchAlarmOpen_\(type.rawValue)")
    }

    private func repeatIDs(for type: WatchAlertType) -> [String] {
        (1 ... Self.repeatCount).map { "\(type.notificationID)-r\($0)" }
    }

    /// Its first notification and every repeat.
    private func notificationIDs(for type: WatchAlertType) -> [String] {
        [type.notificationID] + repeatIDs(for: type)
    }

    /// The latest reading checked, for the repeats scheduled after a Stop or Snooze. Kept in
    /// memory, on `alertQueue`: after a relaunch the repeats already scheduled run on until the
    /// next reading.
    private var lastReading: (bg: Double, delta: Double?)?

    private var openAlarms: [WatchAlertType] {
        WatchAlertType.allCases.filter(isOpen)
    }

    /// Whether the alarm is sounding, unanswered.
    func isSounding(_ type: WatchAlertType) -> Bool {
        isOpen(type)
    }

    /// Every alert whose own threshold the snapshot meets. Unlike `triggeredAlerts`, a low under
    /// an urgent low counts, so an alarm that's sounding stays on for as long as it's met.
    private func metAlerts(for snapshot: GlucoseSnapshot) -> Set<WatchAlertType> {
        guard snapshot.updatedAt > Date(timeIntervalSinceNow: -15 * 60) else { return [] }
        let bg = snapshot.glucose
        var met = Set<WatchAlertType>()
        if bg <= thresholds.urgentLow { met.insert(.urgentLow) }
        if bg < thresholds.low { met.insert(.lowBG) }
        if bg > thresholds.high { met.insert(.highBG) }
        if let rate = snapshot.deltaRate {
            if rate < -thresholds.dropRate { met.insert(.fastDrop) }
            if rate > thresholds.riseRate { met.insert(.fastRise) }
        }
        return met
    }

    /// Ends the alarms that are snoozed or whose threshold is no longer met. Over by itself, an
    /// alarm keeps its first notification as a record; its repeats go.
    private func closeAnswered(met: Set<WatchAlertType>) {
        for type in openAlarms where !met.contains(type) || isSnoozed(for: type) {
            setOpen(type, false)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: repeatIDs(for: type))
        }
    }

    /// Schedules the next stretch of repeats for the most urgent alarm still sounding, in place of
    /// any scheduled before. Without a reading since launch it leaves those already scheduled.
    private func scheduleRepeats() {
        guard let reading = lastReading else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: WatchAlertType.allCases.flatMap(repeatIDs(for:)))
        guard let type = Self.repeatPriority.first(where: { isOpen($0) && !isSnoozed(for: $0) }) else { return }
        for (index, id) in repeatIDs(for: type).enumerated() {
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.repeatInterval * Double(index + 1), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content(for: type, bg: reading.bg, delta: reading.delta), trigger: trigger))
        }
        os_log("WatchAlertManager: %{public}@ repeats every %ds", log: alertLog, type: .info, type.rawValue, Int(Self.repeatInterval))
    }

    /// For the page: the alarms changed.
    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .watchAlarmsChanged, object: nil)
        }
    }

    /// Stop: the alarm stops sounding and comes back a full cooldown after the Stop, if its
    /// threshold is still met then. An urgent low covers a low, so stopping it stops both. The
    /// next most urgent alarm still sounding takes over the repeats.
    func stop(type: WatchAlertType) {
        alertQueue.sync {
            let stopped: [WatchAlertType] = type == .urgentLow ? [.urgentLow, .lowBG] : [type]
            // A Stop on an old notification, of an alarm already over, starts no cooldown.
            if isOpen(type) {
                let now = Date().timeIntervalSince1970
                stopped.forEach { defaults.set(now, forKey: $0.cooldownKey) }
            }
            stopped.forEach { setOpen($0, false) }
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: stopped.flatMap(repeatIDs(for:)))
            center.removeDeliveredNotifications(withIdentifiers: stopped.flatMap(notificationIDs(for:)))
            scheduleRepeats()
        }
        notifyChanged()
        os_log("WatchAlertManager: stopped %{public}@", log: alertLog, type: .info, type.rawValue)
    }

    /// App Group defaults — shared with main app target.
    private let defaults = UserDefaults(suiteName: AppGroupID.current()) ?? .standard

    // MARK: - Snooze

    /// The snooze of every alert, which doesn't reach urgent low: that's snoozed only on its own,
    /// or by a snooze of everything while it's sounding.
    private func globalSnooze(for type: WatchAlertType) -> TimeInterval {
        type == .urgentLow ? 0 : defaults.double(forKey: globalSnoozeKey)
    }

    /// Returns true if this alert type is currently suppressed (global OR per-type snooze active).
    func isSnoozed(for type: WatchAlertType) -> Bool {
        let now = Date().timeIntervalSince1970
        let global = globalSnooze(for: type)
        let perType = defaults.double(forKey: type.snoozeKey)
        return now < global || now < perType
    }

    /// Returns the latest active snooze expiry for this type (global or per-type), or nil.
    func snoozeUntil(for type: WatchAlertType) -> Date? {
        let now = Date().timeIntervalSince1970
        let global = globalSnooze(for: type)
        let perType = defaults.double(forKey: type.snoozeKey)
        let until = max(global, perType)
        return until > now ? Date(timeIntervalSince1970: until) : nil
    }

    /// True only if the global (all-types) snooze is currently active.
    var isGloballySnoozed: Bool {
        defaults.double(forKey: globalSnoozeKey) > Date().timeIntervalSince1970
    }

    /// Expiry date of the global snooze, or nil if not active.
    var globalSnoozeExpiryDate: Date? {
        let until = defaults.double(forKey: globalSnoozeKey)
        let now = Date().timeIntervalSince1970
        return until > now ? Date(timeIntervalSince1970: until) : nil
    }

    /// Snooze. Pass nil type for global snooze; pass a specific type for per-type snooze. An urgent
    /// low covers a low, so snoozing it snoozes both; a snooze of everything leaves urgent low able
    /// to sound unless it's sounding now. The snoozed alarms stop, and their notifications are
    /// cleared away as answered; any other alarm still sounding keeps repeating.
    func snooze(minutes: Int, type: WatchAlertType?) {
        let until = Date().timeIntervalSince1970 + Double(minutes * 60)
        alertQueue.sync {
            if let type {
                let snoozed: [WatchAlertType] = type == .urgentLow ? [.urgentLow, .lowBG] : [type]
                snoozed.forEach { defaults.set(until, forKey: $0.snoozeKey) }
                os_log("WatchAlertManager: snoozed %{public}@ for %d min", log: alertLog, type: .info, type.rawValue, minutes)
            } else {
                defaults.set(until, forKey: globalSnoozeKey)
                if isOpen(.urgentLow) {
                    defaults.set(until, forKey: WatchAlertType.urgentLow.snoozeKey)
                }
                os_log("WatchAlertManager: snoozed all for %d min", log: alertLog, type: .info, minutes)
            }
            let snoozed = WatchAlertType.allCases.filter { isSnoozed(for: $0) }
            snoozed.forEach { setOpen($0, false) }
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: snoozed.flatMap(repeatIDs(for:)))
            center.removeDeliveredNotifications(withIdentifiers: snoozed.flatMap(notificationIDs(for:)))
            scheduleRepeats()
        }
        notifyChanged()
    }

    /// Cancel snooze. Nil clears only the global snooze; specific type clears only that type.
    /// Per-type snoozes set from notification actions are not affected by a nil cancel.
    func cancelSnooze(type: WatchAlertType?) {
        if let type = type {
            defaults.set(0, forKey: type.snoozeKey)
        } else {
            defaults.set(0, forKey: globalSnoozeKey)
        }
        os_log("WatchAlertManager: snooze cancelled", log: alertLog, type: .info)
        notifyChanged()
    }

    // MARK: - Setup (call once from applicationDidFinishLaunching)

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        // Sound, so an alarm can be heard like the phone's; a watch in silent mode still taps.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            os_log("WatchAlertManager: permission granted=%d", log: alertLog, type: .info, granted)
        }
    }

    private func registerNotificationCategories() {
        // Snooze for the snooze screen's default length in one tap, or choose on it.
        let snoozeDefault = UNNotificationAction(
            identifier: "SNOOZE_DEFAULT",
            title: "Snooze \(settings.defaultSnoozeMinutes) min",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: "SNOOZE_ALERT",
            title: "Snooze…",
            options: [.foreground]
        )
        // Stops this alarm repeating; it can come back after its cooldown.
        let stop = UNNotificationAction(
            identifier: "DISMISS_ALERT",
            title: "Stop",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "GLUCOSE_ALERT",
            actions: [snoozeDefault, snooze, stop],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Active alert query

    /// The alerts whose thresholds the snapshot meets, weighed as `checkAndAlert` weighs them,
    /// regardless of cooldown or snooze.
    func triggeredAlerts(for snapshot: GlucoseSnapshot) -> [WatchAlertType] {
        guard snapshot.updatedAt > Date(timeIntervalSinceNow: -15 * 60) else { return [] }
        let bg = snapshot.glucose
        let delta = snapshot.deltaRate
        if bg <= thresholds.urgentLow { return [.urgentLow] }
        if bg < thresholds.low { return [.lowBG] }
        var types: [WatchAlertType] = []
        if bg > thresholds.high { types.append(.highBG) }
        if delta.map({ $0 < -thresholds.dropRate }) ?? false { types.append(.fastDrop) }
        if delta.map({ $0 > thresholds.riseRate }) ?? false { types.append(.fastRise) }
        return types
    }

    /// What the glucose page offers for the alerts.
    enum SnoozeStatus: Equatable {
        case none
        /// An alarm is sounding, unanswered: Snooze and Stop buttons.
        case active
        /// Alerts are snoozed until then: a Cancel button.
        case snoozed(until: Date)
    }

    func snoozeStatus(for snapshot: GlucoseSnapshot?) -> SnoozeStatus {
        // A sounding alarm first, so it can always be snoozed or stopped.
        if !openAlarms.isEmpty { return .active }
        // A snooze of every alert shows whatever BG is doing, so it can always be cancelled.
        if let until = globalSnoozeExpiryDate { return .snoozed(until: until) }
        // Each alert met is snoozed on its own, from its notification.
        let met = snapshot.map(metAlerts(for:)) ?? []
        if let until = met.compactMap({ snoozeUntil(for: $0) }).max() { return .snoozed(until: until) }
        return .none
    }

    /// Stops every sounding alarm, as Stop on each of their notifications would.
    func stopAll() {
        let sounding = alertQueue.sync { openAlarms }
        sounding.forEach(stop(type:))
    }

    /// Ends every snooze, of all alerts and of each on its own, so alerts sound again when met.
    func cancelAllSnoozes() {
        defaults.set(0, forKey: globalSnoozeKey)
        for type in WatchAlertType.allCases {
            defaults.set(0, forKey: type.snoozeKey)
        }
        os_log("WatchAlertManager: all snoozes cancelled", log: alertLog, type: .info)
        notifyChanged()
    }

    // MARK: - Check (main entry point — call from both WC and background refresh paths)

    func checkAndAlert(snapshot: GlucoseSnapshot) {
        // Staleness gate: cheap read with no shared state — keep outside the serial queue.
        guard snapshot.updatedAt > Date(timeIntervalSinceNow: -15 * 60) else {
            os_log("WatchAlertManager: snapshot too stale, skipping", log: alertLog, type: .debug)
            return
        }

        alertQueue.sync {
            let before = openAlarms
            let bg = snapshot.glucose
            let delta = snapshot.deltaRate
            lastReading = (bg, delta)
            // Urgent low alone when met; low keeps fast drop quiet.
            for type in triggeredAlerts(for: snapshot) {
                evaluate(type, bg: bg, delta: delta)
            }
            closeAnswered(met: metAlerts(for: snapshot))
            scheduleRepeats()
            if openAlarms != before { notifyChanged() }
        }
    }

    /// For a reading the Watch fetched from Nightscout itself: ends the alarms it no longer meets
    /// and keeps the rest repeating, but starts none, as its rate of change can span a missed
    /// reading.
    func resolve(snapshot: GlucoseSnapshot) {
        guard snapshot.updatedAt > Date(timeIntervalSinceNow: -15 * 60) else { return }
        alertQueue.sync {
            let before = openAlarms
            lastReading = (snapshot.glucose, snapshot.deltaRate)
            closeAnswered(met: metAlerts(for: snapshot))
            scheduleRepeats()
            if openAlarms != before { notifyChanged() }
        }
    }

    // MARK: - Private

    /// Fires an alarm whose threshold is met, unless it's snoozed, already sounding or cooling down.
    private func evaluate(_ type: WatchAlertType, bg: Double, delta: Double?) {
        guard !isSnoozed(for: type), !isOpen(type) else { return }

        let now = Date().timeIntervalSince1970
        let lastFired = defaults.double(forKey: type.cooldownKey)
        guard now - lastFired >= settings.cooldown(for: type) else { return }

        fire(type: type, bg: bg, delta: delta)
        defaults.set(now, forKey: type.cooldownKey)
        setOpen(type, true)
    }

    /// An alarm's notification, the first and each repeat alike.
    private func content(for type: WatchAlertType, bg: Double, delta: Double?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.body(bg: bg, delta: delta)
        content.sound = .default
        content.interruptionLevel = (type == .urgentLow) ? .timeSensitive : .active
        content.categoryIdentifier = "GLUCOSE_ALERT"
        // Its repeats gather under it in Notification Center.
        content.threadIdentifier = type.notificationID
        // Which alarm it is, whichever of its notifications is answered.
        content.userInfo = ["alertType": type.rawValue]
        return content
    }

    private func fire(type: WatchAlertType, bg: Double, delta: Double?) {
        let request = UNNotificationRequest(
            identifier: type.notificationID, // stable ID — replaces any pending same-type alert
            content: content(for: type, bg: bg, delta: delta),
            trigger: nil // immediate delivery
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                os_log("WatchAlertManager: failed %{public}@ — %{public}@",
                       log: alertLog, type: .error, type.rawValue, error.localizedDescription)
            } else {
                os_log("WatchAlertManager: fired %{public}@ bg=%d",
                       log: alertLog, type: .info, type.rawValue, Int(bg))
            }
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
        let request = response.notification.request
        // From the notification itself; one posted before it carried its type, from its identifier.
        let alertType = (request.content.userInfo["alertType"] as? String).flatMap(WatchAlertType.init(rawValue:))
            ?? WatchAlertType.allCases.first { request.identifier.hasPrefix($0.notificationID) }

        switch response.actionIdentifier {
        case "DISMISS_ALERT":
            // Shown as Stop.
            if let type = alertType { stop(type: type) }

        case "SNOOZE_DEFAULT":
            // Only the alarm answered, for the default length, as the phone's Snooze does.
            // Snoozing everything is on the snooze screen, where it says so.
            if let type = alertType {
                snooze(minutes: settings.defaultSnoozeMinutes, type: type)
            }

        case "SNOOZE_ALERT":
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .showSnoozeSheet,
                    object: nil,
                    userInfo: alertType.map { ["alertType": $0.rawValue] }
                )
            }

        default:
            break
        }
        completionHandler()
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
