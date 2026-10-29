// LoopFollow
// WatchConnectivityManager.swift

import Combine
import Foundation
import UIKit
import WatchConnectivity

final class WatchConnectivityManager: NSObject {
    // MARK: - Shared Instance

    static let shared = WatchConnectivityManager()

    // MARK: - Init

    /// Timestamp of the last snapshot the Watch ACK'd via sendAck().
    private var lastWatchAckTimestamp: TimeInterval = 0
    /// Timestamp of the last high-priority complication push.
    /// In-memory only — resets on launch, which is fine since the phone app runs continuously.
    private var lastComplicationPushTime: Date = .distantPast
    /// Timestamp of the last remote command received from the Watch.
    private var lastWatchCommandDate: Date = .distantPast
    /// When the Watch last asked for a refresh; requests closer together than
    /// `watchRefreshInterval` reuse the fetch already under way.
    private var lastWatchRefresh: Date = .distantPast
    private static let watchRefreshInterval: TimeInterval = 15
    /// BG, device status and treatments land within a few seconds of a refresh.
    private static let refreshPushDelay: TimeInterval = 8
    /// Background time held from a Watch refresh until its result has been sent.
    private var refreshBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Settings most recently handed to WatchConnectivity, used to skip redundant pushes.
    private var lastSentSettings: WatchSettings?
    /// The alarm state most recently handed to WatchConnectivity, likewise.
    private var lastSentAlarmState: WatchAlarmState?
    /// When the payload went out that took the last alarm start or end on the high-priority
    /// channel, so a later send doesn't cancel it while it's still on its way.
    private var urgentAlarmSentAt: TimeInterval?
    /// When the latest payload went out, so a failed live message that has been overtaken isn't
    /// queued after it.
    private var latestAlarmsSentAt: TimeInterval?
    /// The sounding last answered from the Watch, whose end the Watch already knows of.
    private var answeredFromWatch: String?
    /// While an alarm sounds, unchanged state still goes out this often, so the Watch keeps
    /// repeating it for as long as the phone does, within its 8 minutes of repeats.
    private static let soundingResendInterval: TimeInterval = 4 * 60
    /// Checks for that resend while an alarm sounds; nil otherwise.
    private var soundingResendTimer: Timer?
    /// What the last snapshot send carried, and when. The phone refreshes far more often than
    /// anything changes, and every send can wake the Watch, so an identical send is skipped.
    private var lastSentContent: SentContent?
    private var lastSentAt: Date = .distantPast
    /// Unchanged state still goes out this often, so the Watch's 24-hour stats keep moving.
    private static let resendInterval: TimeInterval = 15 * 60
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
    }

    // MARK: - Setup

    /// Call once from AppDelegate after app launch.
    func activate() {
        guard WCSession.isSupported() else {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: WCSession not supported on this device")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        observeWatchSettings()
        observeAlarms()
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: WCSession activation requested")
    }

    // MARK: - Payload

    /// Builds the settings the Watch needs from the phone's own storage.
    func currentSettings() -> WatchSettings {
        // Same range the phone's chart and stats use (TIR/TITR presets or custom lines).
        let thresholds = UnitSettingsStore.shared.effectiveThresholds()
        let remoteSystem = WatchCommandDispatcher.activeRemoteSystem()
        return WatchSettings(
            lowMgdl: thresholds.low,
            highMgdl: thresholds.high,
            remoteEnabled: remoteSystem != nil,
            maxBolus: Storage.shared.maxBolus.value.doubleValue(for: .internationalUnit()),
            maxCarbs: Storage.shared.maxCarbs.value.doubleValue(for: .gram()),
            overridePresets: LAAppGroupSettings.watchOverridePresets(),
            nightscoutURL: Storage.shared.url.value,
            nightscoutToken: Storage.shared.token.value,
            remoteSystem: remoteSystem ?? .loop,
            bolusIncrement: Storage.shared.bolusIncrement.value.doubleValue(for: .internationalUnit()),
            pumpAgeColoring: Self.ageColoring(for: .cage),
            sensorAgeColoring: Self.ageColoring(for: .sage),
            trioRemote: remoteSystem == .trio ? Self.trioRemote() : nil
        )
    }

    /// The phone's alarms, which the Watch mirrors. Call on the main thread.
    private func currentAlarmState(now: Date = Date()) -> WatchAlarmState {
        WatchAlarmState.make(
            alarms: Storage.shared.alarms.value,
            config: Storage.shared.alarmConfiguration.value,
            sounding: AlarmManager.shared.sounding,
            currentAlarm: Observable.shared.currentAlarm.value,
            now: now
        )
    }

    /// What the phone's Trio remote screens offer, for the Watch's.
    private static func trioRemote() -> WatchTrioRemote {
        WatchTrioRemote(
            mealWithBolus: Storage.shared.mealWithBolus.value,
            mealWithFatProtein: Storage.shared.mealWithFatProtein.value,
            maxFat: Storage.shared.maxFat.value.doubleValue(for: .gram()),
            maxProtein: Storage.shared.maxProtein.value.doubleValue(for: .gram()),
            tempTargetPresets: TempTargetPresetManager.shared.presets.map {
                WatchTrioRemote.TempTargetPreset(
                    name: $0.name,
                    targetMgdl: $0.target.doubleValue(for: .milligramsPerDeciliter),
                    durationMinutes: $0.duration.doubleValue(for: .minute())
                )
            },
            overrides: ProfileManager.shared.trioOverrides.map {
                WatchTrioRemote.Override(
                    name: $0.name,
                    durationMinutes: $0.duration,
                    percentage: $0.percentage,
                    targetMgdl: $0.target?.doubleValue(for: .milligramsPerDeciliter)
                )
            }
        )
    }

    /// An Info Display row's coloring, which the Watch's pump and sensor ages follow; nil while
    /// it's off.
    private static func ageColoring(for type: InfoType) -> AgeColoring? {
        guard let coloring = Storage.shared.infoDisplayItems.value.item(for: type)?.coloring,
              coloring.enabled
        else { return nil }
        return AgeColoring(warningDays: coloring.warning, urgentDays: coloring.urgent)
    }

    private func encode(_ snapshot: GlucoseSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    /// The parts of a payload the Watch acts on, without the build time that makes every
    /// payload different. When treatments were last downloaded is left out as well: the Watch
    /// only compares it with the newest reading, and a new reading brings it along.
    private struct SentContent: Equatable {
        let settings: WatchSettings
        let alarms: WatchAlarmState
        let snapshot: GlucoseSnapshot
        let newestReading: TimeInterval?
        let readingCount: Int
        let treatments: [WatchTreatmentHistory.Treatment]?
    }

    /// Call on the main thread, like `makePayload`.
    private func sentContent(snapshot: GlucoseSnapshot, now: Date) -> SentContent {
        let readings = Thread.isMainThread ? MainViewController.shared?.bgData ?? [] : []
        return SentContent(
            settings: currentSettings(),
            alarms: currentAlarmState(now: now),
            snapshot: snapshot,
            newestReading: readings.last?.date,
            readingCount: readings.count,
            treatments: currentTreatmentHistory(now: now)?.treatments
        )
    }

    /// Every payload carries the current settings, so whichever channel reaches the
    /// Watch first also brings it up to date. `updateApplicationContext` replaces the
    /// whole context, which is another reason everything must always travel together.
    /// Call on the main thread, and only once storage is ready: before the first unlock after
    /// a restart the settings read as defaults, which would wipe the Watch's own copy.
    private func makePayload(snapshot: GlucoseSnapshot?) -> [String: Any] {
        var payload: [String: Any] = [:]
        let settings = currentSettings()
        if let data = try? settings.encoded() {
            payload[WatchSettings.payloadKey] = data
            lastSentSettings = settings
        }
        if let snapshot, let data = try? encode(snapshot) {
            payload["snapshot"] = data
        }
        let now = Date()
        let alarms = currentAlarmState(now: now)
        if let data = try? alarms.encoded() {
            payload[WatchAlarmState.payloadKey] = data
            payload[WatchAlarmState.sentAtKey] = now.timeIntervalSince1970
            lastSentAlarmState = alarms
            latestAlarmsSentAt = now.timeIntervalSince1970
        }
        let readings = currentReadings()
        if !readings.isEmpty, let data = try? WatchGlucoseHistory.make(from: readings, now: now).encoded() {
            payload[WatchGlucoseHistory.payloadKey] = data
        }
        if let treatments = currentTreatmentHistory(now: now), let data = try? treatments.encoded() {
            payload[WatchTreatmentHistory.payloadKey] = data
        }
        if let stats = WatchStatsSummary.make(
            from: readings,
            lowMgdl: settings.lowMgdl,
            highMgdl: settings.highMgdl,
            now: now
        ), let data = try? stats.encoded() {
            payload[WatchStatsSummary.payloadKey] = data
        }
        return payload
    }

    /// Readings for the Watch graph and stats. `bgData` is owned by the main thread; off
    /// main the keys are simply omitted and the Watch keeps what it already has.
    private func currentReadings() -> [WatchGlucoseHistory.Point] {
        guard Thread.isMainThread, let readings = MainViewController.shared?.bgData else { return [] }
        return readings.map { WatchGlucoseHistory.Point(date: $0.date, mgdl: $0.sgv) }
    }

    /// Boluses, SMBs and carbs for the Watch graph, filtered and labelled like the iPhone
    /// graph. Nil off main, where the treatment arrays can't be read, and before the first
    /// treatment download, so the Watch keeps what it has instead of clearing it.
    private func currentTreatmentHistory(now: Date) -> WatchTreatmentHistory? {
        guard Thread.isMainThread, let vc = MainViewController.shared else { return nil }
        if IsNightscoutEnabled(), Storage.shared.downloadTreatments.value, vc.treatmentsUpdatedAt == nil {
            return nil
        }
        // Only the Watch's window needs labels; the arrays can hold days of treatments.
        let nowSeconds = now.timeIntervalSince1970
        let inWindow: (TimeInterval) -> Bool = { WatchTreatmentHistory.isInWindow($0, now: nowSeconds) }
        let showValues = Storage.shared.showValues.value
        var treatments: [WatchTreatmentHistory.Treatment] = []
        if Storage.shared.graphBolus.value {
            treatments += vc.bolusData.filter { inWindow($0.date) }.map {
                WatchTreatmentHistory.Treatment(kind: .bolus, date: $0.date, mgdl: $0.sgv, label: showValues ? WatchTreatmentHistory.doseLabel($0.value) : "")
            }
            treatments += vc.smbData.filter { inWindow($0.date) }.map {
                WatchTreatmentHistory.Treatment(kind: .smb, date: $0.date, mgdl: $0.sgv, label: showValues ? WatchTreatmentHistory.doseLabel($0.value) : "")
            }
        }
        if Storage.shared.graphCarbs.value {
            let showAbsorption = Storage.shared.showAbsorption.value
            treatments += vc.carbData.filter { inWindow($0.date) }.map {
                let label = WatchTreatmentHistory.carbLabel(grams: Int($0.value), absorptionMinutes: $0.absorptionTime, showAbsorption: showAbsorption)
                return WatchTreatmentHistory.Treatment(kind: .carbs, date: $0.date, mgdl: $0.sgv, label: showValues ? label : "")
            }
        }
        return WatchTreatmentHistory.make(from: treatments, asOf: vc.treatmentsUpdatedAt?.timeIntervalSince1970, now: now)
    }

    // MARK: - Refresh

    /// The Watch's pull-to-refresh: re-runs every Nightscout fetch now, as pulling down on the
    /// phone's home screen does, and sends the result a few seconds later. Returns false when
    /// the phone can't fetch (locked since a restart, or no data pipeline yet), so the Watch can
    /// poll Nightscout itself. Call on the main thread.
    private func refreshForWatch() -> Bool {
        // Before the first unlock after a reboot, settings can't be read yet; don't fetch with defaults.
        guard StorageReadiness.ready.value, let vc = MainViewController.shared else { return false }
        let now = Date()
        // Requests closer together than this reuse the fetch already under way.
        guard now.timeIntervalSince(lastWatchRefresh) >= Self.watchRefreshInterval else { return true }
        if UIApplication.shared.applicationState == .background {
            // A message from the Watch only wakes the app briefly; hold background time until the
            // result has gone out. Without it iOS may suspend the app first, and the Watch should
            // poll Nightscout itself instead.
            endRefreshBackgroundTask()
            refreshBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WatchRefresh") { [weak self] in
                self?.endRefreshBackgroundTask()
            }
            guard refreshBackgroundTask != .invalid else { return false }
            // The Nightscout WebSocket is foreground-only (it closes when the app goes to the
            // background) and refresh() would reopen it, so only re-run the fetches.
            vc.scheduleAllTasks()
        } else {
            vc.refresh()
        }
        lastWatchRefresh = now
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch asked for a refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshPushDelay) { [weak self] in
            self?.pushCurrentState()
            self?.endRefreshBackgroundTask()
        }
        return true
    }

    private func endRefreshBackgroundTask() {
        guard refreshBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(refreshBackgroundTask)
        refreshBackgroundTask = .invalid
    }

    /// Sends the phone's current state to a reachable Watch right away, without waiting for
    /// the next Live Activity refresh. Call on the main thread.
    private func pushCurrentState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(makePayload(snapshot: currentSnapshot()), replyHandler: nil, errorHandler: nil)
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: refreshed state sent to Watch")
    }

    /// The phone's current values as a snapshot, or the last stored one when they're incomplete.
    private func currentSnapshot() -> GlucoseSnapshot? {
        GlucoseSnapshotBuilder.build(from: StorageCurrentGlucoseStateProvider()) ?? GlucoseSnapshotStore.shared.load()
    }

    // MARK: - Send Settings

    /// Pushes settings when they differ from what was last handed to WatchConnectivity.
    func pushSettingsIfChanged() {
        guard currentSettings() != lastSentSettings else { return }
        pushSettings()
    }

    private func pushSettings() {
        guard WCSession.isSupported(), StorageReadiness.ready.value else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }

        let payload = makePayload(snapshot: GlucoseSnapshotStore.shared.load())
        do {
            try session.updateApplicationContext(payload)
        } catch {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: failed to update applicationContext with settings — \(error)")
        }
        if session.isReachable, let settings = payload[WatchSettings.payloadKey] {
            session.sendMessage([WatchSettings.payloadKey: settings], replyHandler: nil, errorHandler: nil)
        }
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: settings pushed to Watch", isDebug: true)
    }

    // MARK: - Send Snapshot

    /// Sends the latest GlucoseSnapshot, with settings, history and stats, to the Watch.
    /// Call on the main thread so the payload includes the BG readings.
    /// Skips quietly when there is no Watch app, and when nothing has changed since the last
    /// send unless `force` is set; a forced resend of unchanged state goes out as a live
    /// message only, since the Watch already has the rest. An alarm starting or ending takes the
    /// high-priority channel whenever any of its daily budget is left.
    func send(snapshot: GlucoseSnapshot, force: Bool = false) {
        guard WCSession.isSupported(), StorageReadiness.ready.value else { return }

        let session = WCSession.default
        // Most LoopFollow users have no Watch app; build and queue nothing for them.
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }

        let now = Date()
        let content = sentContent(snapshot: snapshot, now: now)
        // An alarm state the Watch had in a reply, or with the settings, counts too, so a change
        // back to what the last send carried still goes out.
        let resendInterval = content.alarms.sounding == nil ? Self.resendInterval : Self.soundingResendInterval
        let unchanged = content == lastSentContent && content.alarms == lastSentAlarmState
            && now.timeIntervalSince(lastSentAt) < resendInterval
        if unchanged, !force { return }
        // The Watch should sound, or fall quiet, with the phone; an end the Watch caused itself, by
        // a snooze or stop, it knows of already.
        let previous = lastSentContent?.alarms.sounding
        let alarmStartedOrEnded = content.alarms.sounding?.key != previous?.key
        let urgent = alarmStartedOrEnded && !(content.alarms.sounding == nil && previous?.key == answeredFromWatch)

        let payload = makePayload(snapshot: snapshot)
        guard payload["snapshot"] != nil else {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: failed to encode snapshot")
            return
        }

        // Warn if Watch hasn't ACK'd this or a recent snapshot.
        let behindBy = snapshot.updatedAt.timeIntervalSince1970 - lastWatchAckTimestamp
        if lastWatchAckTimestamp > 0, behindBy > 600 {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch ACK is \(Int(behindBy))s behind — Watch may be missing deliveries")
        }

        // The Watch app is open: deliver now, and queue it only if that fails; an alarm starting
        // or ending, on the faster channel.
        if session.isReachable {
            let sentAt = payload[WatchAlarmState.sentAtKey] as? TimeInterval
            session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                DispatchQueue.main.async {
                    // A later payload has gone out since and carries all of this.
                    guard sentAt == self.latestAlarmsSentAt else { return }
                    if urgent, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
                        self.urgentAlarmSentAt = sentAt
                        session.transferCurrentComplicationUserInfo(payload)
                    } else {
                        session.transferUserInfo(payload)
                    }
                }
            })
        }
        guard !unchanged else { return }

        // Only the latest state matters, so a queued older one is dropped; a queued bolus or
        // carb confirmation is not, nor an alarm's start or end still on its way on the faster
        // channel, unless this send brings the next one.
        session.outstandingUserInfoTransfers
            .filter { $0.userInfo["snapshot"] != nil && (alarmStartedOrEnded || !isUrgentAlarmTransfer($0)) }
            .forEach { $0.cancel() }

        // applicationContext: always keep latest state for the app refresh path.
        do {
            try session.updateApplicationContext(payload)
            lastSentContent = content
            lastSentAt = now
        } catch {
            LogManager.shared.log(
                category: .watch,
                message: "WatchConnectivityManager: failed to update applicationContext — \(error)"
            )
        }

        // An open Watch app already has it from the message above and reloads its own
        // complications. Otherwise:
        //   Every 30 min → transferCurrentComplicationUserInfo (high-priority wake, 50/day budget)
        //   Every  5 min → transferUserInfo (queued fallback, no documented cap)
        // Outstanding transfers are cancelled above so at most one is ever pending, besides an
        // alarm's start or end still on its way.
        guard !session.isReachable else { return }
        let transferLog: String
        if session.isComplicationEnabled,
           WatchRefreshPolicy.isComplicationPushDue(
               now: now,
               lastPush: lastComplicationPushTime,
               remainingTransfers: session.remainingComplicationUserInfoTransfers,
               urgent: urgent
           )
        {
            session.transferCurrentComplicationUserInfo(payload)
            lastComplicationPushTime = now
            if urgent {
                urgentAlarmSentAt = payload[WatchAlarmState.sentAtKey] as? TimeInterval
            }
            transferLog = "snapshot sent via transferCurrentComplicationUserInfo"
        } else {
            session.transferUserInfo(payload)
            transferLog = "snapshot sent via transferUserInfo"
        }
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: \(transferLog)", isDebug: true)
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(
        _: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: activation failed — \(error)")
        } else {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: activation complete — state \(activationState.rawValue)")
            // Payloads are built on main, where the BG readings live, from settings that can
            // only be read once storage is ready.
            DispatchQueue.main.async { StorageReadiness.whenReady { self.pushSettings() } }
        }
    }

    /// Receives ACKs from the Watch (sent after each snapshot is saved, in debug builds), and its
    /// snoozes and stops of alarms.
    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        if handleAlarmCommand(message) { return }
        if let ackTimestamp = message["watchAck"] as? TimeInterval {
            DispatchQueue.main.async { self.lastWatchAckTimestamp = ackTimestamp }
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch ACK received for snapshot at \(ackTimestamp)", isDebug: true)
        }
    }

    /// Handles remote command messages sent from the Watch with a reply handler.
    func session(
        _: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if handleAlarmCommand(message) {
            replyHandler(["success": true])
            return
        }
        if message["watchRequestRefresh"] != nil {
            DispatchQueue.main.async {
                let fetching = self.refreshForWatch()
                // Answer with what the phone has now; what it fetches follows a few seconds later.
                var reply = StorageReadiness.ready.value ? self.makePayload(snapshot: self.currentSnapshot()) : [:]
                reply["refreshing"] = fetching
                replyHandler(reply)
            }
            return
        }
        if message["watchRequestSettings"] != nil {
            DispatchQueue.main.async {
                replyHandler(StorageReadiness.ready.value ? self.makePayload(snapshot: GlucoseSnapshotStore.shared.load()) : [:])
                LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: answered Watch settings request")
            }
            return
        }
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: received Watch command — \(message["watchCmd"] as? String ?? "unknown")")
        // Commands read the phone's settings, which belong to the main thread.
        DispatchQueue.main.async {
            self.lastWatchCommandDate = Date()
            WatchCommandDispatcher.shared.handle(message: message, replyHandler: replyHandler)
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if handleAlarmCommand(userInfo) { return }
        if let ackTimestamp = userInfo["watchAck"] as? TimeInterval {
            DispatchQueue.main.async { self.lastWatchAckTimestamp = ackTimestamp }
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch ACK (userInfo) received for snapshot at \(ackTimestamp)", isDebug: true)
        }
    }

    /// When the Watch app comes to the foreground, send the latest snapshot immediately
    /// so the Watch app has fresh data without waiting for the next BG poll.
    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        DispatchQueue.main.async {
            if let snapshot = GlucoseSnapshotStore.shared.load() {
                self.send(snapshot: snapshot, force: true)
                LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch became reachable — snapshot pushed", isDebug: true)
            } else {
                self.pushSettings()
            }
        }
    }

    /// Sends everything as soon as the Watch app is installed, rather than at the next reading.
    func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        DispatchQueue.main.async {
            StorageReadiness.whenReady {
                if let snapshot = GlucoseSnapshotStore.shared.load() {
                    self.send(snapshot: snapshot, force: true)
                } else {
                    self.pushSettings()
                }
            }
        }
    }

    func sessionDidBecomeInactive(_: WCSession) {
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: session became inactive")
    }

    func sessionDidDeactivate(_: WCSession) {
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: session deactivated — reactivating")
        WCSession.default.activate()
    }

    /// Forwards a Loop command return notification to the Watch as a local notification trigger.
    /// Called from AppDelegate when a remote notification arrives. Forwards if:
    ///   - the notification contains command_status/command_type (Loop explicit fields), OR
    ///   - a Watch command was dispatched within the last 2 minutes (time-window correlation).
    func forwardCommandReturnToWatch(userInfo: [AnyHashable: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }

        let hasCommandFields = userInfo["command_status"] != nil || userInfo["command_type"] != nil
        let recentWatchCommand = Date().timeIntervalSince(lastWatchCommandDate) < 120
        let hasAlert: Bool = {
            guard let aps = userInfo["aps"] as? [String: Any] else { return false }
            return aps["alert"] != nil
        }()

        guard hasCommandFields || (recentWatchCommand && hasAlert) else { return }

        let systemName = (WatchCommandDispatcher.activeRemoteSystem() ?? .loop).displayName
        var title = "\(systemName) Confirmed ✓"
        var body = "Command processed by \(systemName)"

        if let commandType = userInfo["command_type"] as? String {
            switch commandType.lowercased() {
            case "bolus": title = "Bolus Confirmed ✓"
            case "carbs": title = "Carbs Confirmed ✓"
            case "override": title = "Override Confirmed ✓"
            default: break
            }
        }

        if let aps = userInfo["aps"] as? [String: Any] {
            if let alert = aps["alert"] as? [String: Any] {
                title = alert["title"] as? String ?? title
                body = alert["body"] as? String ?? body
            } else if let alertStr = aps["alert"] as? String {
                body = alertStr
            }
        }

        let payload: [String: Any] = ["watchLoopReturn": true, "title": title, "body": body]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: forwarded Loop return to Watch — \(title)")
    }

    /// Observes the storage values behind `WatchSettings` and pushes them when they change.
    private func observeWatchSettings() {
        // One list, typed up front: as a single expression it is too much for the type checker.
        let changes: [AnyPublisher<Void, Never>] = [
            Storage.shared.deviceToken.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.loopAPNSQrCodeURL.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.remoteApnsKey.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.url.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.token.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.lowLine.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.highLine.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.timeInRangeModeRaw.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.maxBolus.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.maxCarbs.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.remoteType.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.device.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.sharedSecret.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.user.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.bundleId.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.bolusIncrement.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.infoDisplayItems.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.mealWithBolus.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.mealWithFatProtein.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.maxFat.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.maxProtein.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Trio's overrides come with the profile, which pushes the settings itself as it loads.
            TempTargetPresetManager.shared.$presets.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.pushSettingsIfChanged()
            }
            .store(in: &cancellables)
    }

    // MARK: - Alarms

    /// Sends the alarm state as soon as it changes, rather than with the next reading: an alarm
    /// starting, ending or snoozed, one turned on or off, or Snooze All set or ended.
    private func observeAlarms() {
        let changes: [AnyPublisher<Void, Never>] = [
            Observable.shared.currentAlarm.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.alarms.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            Storage.shared.alarmConfiguration.$value.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.pushAlarmStateIfChanged()
            }
            .store(in: &cancellables)
    }

    /// Whether a queued transfer is the high-priority one taking an alarm's start or end.
    private func isUrgentAlarmTransfer(_ transfer: WCSessionUserInfoTransfer) -> Bool {
        guard let urgentAlarmSentAt, transfer.isCurrentComplicationInfo else { return false }
        return transfer.userInfo[WatchAlarmState.sentAtKey] as? TimeInterval == urgentAlarmSentAt
    }

    /// Sends everything, with the alarm state, when that differs from what last went out on every
    /// channel, or from what last went out at all, as a reply to the Watch or with the settings.
    private func pushAlarmStateIfChanged() {
        guard StorageReadiness.ready.value else { return }
        let state = currentAlarmState()
        resendWhileSounding(state.sounding != nil)
        guard state != lastSentContent?.alarms || state != lastSentAlarmState else { return }
        if let snapshot = currentSnapshot() {
            send(snapshot: snapshot)
        } else {
            pushSettings()
        }
    }

    /// While an alarm sounds, offers the state to `send` every minute, which sends it again once
    /// `soundingResendInterval` has passed with nothing else going out: a data outage can keep an
    /// alarm such as Not Looping sounding with nothing changing.
    private func resendWhileSounding(_ sounding: Bool) {
        guard sounding else {
            soundingResendTimer?.invalidate()
            soundingResendTimer = nil
            return
        }
        guard soundingResendTimer == nil else { return }
        soundingResendTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, StorageReadiness.ready.value, let snapshot = self.currentSnapshot() else { return }
            self.send(snapshot: snapshot)
        }
    }

    /// Carries out a snooze, stop or cancelled snooze of an alarm from the Watch. Returns false
    /// when the message is something else.
    private func handleAlarmCommand(_ message: [String: Any]) -> Bool {
        guard let data = message[WatchAlarmCommand.payloadKey] as? Data else { return false }
        guard let command = try? WatchAlarmCommand.decoded(from: data) else {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: unreadable alarm command from the Watch")
            return true
        }
        // Alarms belong to the main thread, and can't be read before the first unlock after a restart.
        DispatchQueue.main.async {
            guard StorageReadiness.ready.value else { return }
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: alarm \(command) from the Watch")
            switch command {
            case let .snooze(answer, units):
                self.answeredFromWatch = "\(answer.id.uuidString)@\(answer.since)"
                AlarmManager.shared.snooze(answer, units: units)
            case let .stop(answer):
                self.answeredFromWatch = "\(answer.id.uuidString)@\(answer.since)"
                AlarmManager.shared.stop(answer)
            case let .cancelSnoozes(id, until, allUntil):
                AlarmManager.shared.cancelSnoozes(alarmID: id, until: until, allUntil: allUntil)
            }
        }
        return true
    }
}
