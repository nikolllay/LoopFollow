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
            bolusIncrement: Storage.shared.bolusIncrement.value.doubleValue(for: .internationalUnit())
        )
    }

    private func encode(_ snapshot: GlucoseSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    /// Every payload carries the current settings, so whichever channel reaches the
    /// Watch first also brings it up to date. `updateApplicationContext` replaces the
    /// whole context, which is another reason everything must always travel together.
    /// Call on the main thread.
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
        let readings = currentReadings()
        let now = Date()
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
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return }

        let payload = makePayload(snapshot: GlucoseSnapshotStore.shared.load())
        do {
            try session.updateApplicationContext(payload)
        } catch {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: failed to update applicationContext with settings — \(error)")
        }
        if session.isReachable, let settings = payload[WatchSettings.payloadKey] {
            session.sendMessage([WatchSettings.payloadKey: settings], replyHandler: nil, errorHandler: nil)
        }
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: settings pushed to Watch")
    }

    // MARK: - Send Snapshot

    /// Sends the latest GlucoseSnapshot, with settings, history and stats, to the Watch.
    /// Call on the main thread so the payload includes the BG readings.
    /// No-ops silently if Watch is not paired or reachable.
    func send(snapshot: GlucoseSnapshot) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default

        guard session.activationState == .activated else {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: session not activated, skipping send")
            return
        }

        guard session.isPaired else {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: no paired Watch, skipping send")
            return
        }

        do {
            let payload = makePayload(snapshot: snapshot)
            guard payload["snapshot"] != nil else {
                throw CocoaError(.coderInvalidValue)
            }

            // Warn if Watch hasn't ACK'd this or a recent snapshot.
            let behindBy = snapshot.updatedAt.timeIntervalSince1970 - lastWatchAckTimestamp
            if lastWatchAckTimestamp > 0, behindBy > 600 {
                LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch ACK is \(Int(behindBy))s behind — Watch may be missing deliveries")
            }

            // sendMessage: immediate delivery when Watch app is in foreground.
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
                LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: snapshot sent via sendMessage (reachable)")
            }

            // Cancel any pending transferUserInfo — only the latest snapshot matters.
            session.outstandingUserInfoTransfers.forEach { $0.cancel() }

            // applicationContext: always keep latest state for the app refresh path.
            do {
                try session.updateApplicationContext(payload)
            } catch {
                LogManager.shared.log(
                    category: .watch,
                    message: "WatchConnectivityManager: failed to update applicationContext — \(error)"
                )
            }

            // Delivery cadence:
            //   Every 30 min → transferCurrentComplicationUserInfo (high-priority wake, 50/day budget)
            //   Every  5 min → transferUserInfo (queued fallback, no documented cap)
            // Outstanding transfers are cancelled above so at most one is ever pending.
            let now = Date()
            let transferLog: String

            if session.isComplicationEnabled,
               WatchRefreshPolicy.isComplicationPushDue(
                   now: now,
                   lastPush: lastComplicationPushTime,
                   remainingTransfers: session.remainingComplicationUserInfoTransfers
               )
            {
                session.transferCurrentComplicationUserInfo(payload)
                lastComplicationPushTime = now
                transferLog = "snapshot sent via transferCurrentComplicationUserInfo"
            } else {
                session.transferUserInfo(payload)
                transferLog = "snapshot sent via transferUserInfo"
            }

            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: \(transferLog)")
        } catch {
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: failed to encode snapshot — \(error)")
        }
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
            // Payloads are built on main, where the BG readings live.
            DispatchQueue.main.async { self.pushSettings() }
        }
    }

    /// When the Watch app comes to the foreground, send the latest snapshot immediately
    /// so the Watch app has fresh data without waiting for the next BG poll.
    /// Receives ACKs from the Watch (sent after each snapshot is saved).
    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        if let ackTimestamp = message["watchAck"] as? TimeInterval {
            lastWatchAckTimestamp = ackTimestamp
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch ACK received for snapshot at \(ackTimestamp)")
        }
    }

    /// Handles remote command messages sent from the Watch with a reply handler.
    func session(
        _: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message["watchRequestRefresh"] != nil {
            DispatchQueue.main.async {
                let fetching = self.refreshForWatch()
                // Answer with what the phone has now; what it fetches follows a few seconds later.
                var reply = self.makePayload(snapshot: self.currentSnapshot())
                reply["refreshing"] = fetching
                replyHandler(reply)
            }
            return
        }
        if message["watchRequestSettings"] != nil {
            DispatchQueue.main.async {
                replyHandler(self.makePayload(snapshot: GlucoseSnapshotStore.shared.load()))
                LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: answered Watch settings request")
            }
            return
        }
        LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: received Watch command — \(message["watchCmd"] as? String ?? "unknown")")
        lastWatchCommandDate = Date()
        WatchCommandDispatcher.shared.handle(message: message, replyHandler: replyHandler)
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let ackTimestamp = userInfo["watchAck"] as? TimeInterval {
            lastWatchAckTimestamp = ackTimestamp
            LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch ACK (userInfo) received for snapshot at \(ackTimestamp)")
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        DispatchQueue.main.async {
            if let snapshot = GlucoseSnapshotStore.shared.load() {
                self.send(snapshot: snapshot)
                LogManager.shared.log(category: .watch, message: "WatchConnectivityManager: Watch became reachable — snapshot pushed")
            } else {
                self.pushSettings()
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
        guard session.activationState == .activated, session.isPaired else { return }

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
        Publishers.MergeMany(
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
            Storage.shared.bolusIncrement.$value.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.pushSettingsIfChanged()
        }
        .store(in: &cancellables)
    }
}
