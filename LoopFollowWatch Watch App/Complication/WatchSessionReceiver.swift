// LoopFollow
// WatchSessionReceiver.swift

import Foundation
import os.log
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

private let watchLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.loopfollow.watch",
    category: "Watch"
)

final class WatchSessionReceiver: NSObject {
    // MARK: - Shared Instance

    static let shared = WatchSessionReceiver()

    static let snapshotReceivedNotification = Notification.Name("WatchSnapshotReceived")
    static let settingsRefreshedNotification = Notification.Name("WatchSettingsRefreshed")

    /// Background wakes held open while WatchConnectivity delivers content. Main thread only.
    private var heldConnectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var sessionObservations: [NSKeyValueObservation] = []
    /// Guards the two below, which the WatchConnectivity and store queues use as well as main.
    private let stateLock = NSLock()
    /// Snapshots received and not yet saved; held wakes wait for them.
    private var snapshotsBeingSaved = 0
    /// The settings, history, treatments and stats last applied, by payload key. The phone sends
    /// each update on two or three channels, and the copies after the first change nothing.
    private var lastApplied: [String: Data] = [:]

    // MARK: - Init

    override private init() {
        super.init()
    }

    // MARK: - Setup

    /// Call once from the Watch extension entry point after launch.
    func activate() {
        guard WCSession.isSupported() else {
            os_log("WatchSessionReceiver: WCSession not supported", log: watchLog, type: .debug)
            return
        }
        WCSession.default.delegate = self
        // A held wake ends once WatchConnectivity has nothing more to deliver, as in Apple's
        // sample; one left open keeps using background time until watchOS ends the app.
        sessionObservations = [
            WCSession.default.observe(\.activationState) { [weak self] _, _ in
                DispatchQueue.main.async { self?.completeHeldTasksIfIdle() }
            },
            WCSession.default.observe(\.hasContentPending) { [weak self] _, _ in
                DispatchQueue.main.async { self?.completeHeldTasksIfIdle() }
            },
        ]
        WCSession.default.activate()
        os_log("WatchSessionReceiver: WCSession activation requested", log: watchLog, type: .debug)
    }

    /// Holds a background wake open until WatchConnectivity has delivered what it woke the app
    /// for. Call on the main thread.
    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        heldConnectivityTasks.append(task)
        completeHeldTasksIfIdle()
    }

    /// Ends the held wakes once WatchConnectivity has nothing more to deliver and every snapshot
    /// it brought is saved, with its complication reload requested, so watchOS doesn't suspend
    /// the app halfway. Main thread only.
    private func completeHeldTasksIfIdle() {
        stateLock.lock()
        let saving = snapshotsBeingSaved > 0
        stateLock.unlock()
        let session = WCSession.default
        guard !heldConnectivityTasks.isEmpty, !saving,
              session.activationState == .activated, !session.hasContentPending
        else { return }
        heldConnectivityTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        heldConnectivityTasks.removeAll()
    }

    private func beginSave() {
        stateLock.lock()
        snapshotsBeingSaved += 1
        stateLock.unlock()
    }

    /// Main thread only, after the complication reload has been requested.
    private func endSave() {
        stateLock.lock()
        snapshotsBeingSaved -= 1
        stateLock.unlock()
        completeHeldTasksIfIdle()
    }

    /// True the first time this part of a payload arrives; false for its copies on other channels.
    private func isNewDelivery(_ data: Data, of key: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lastApplied[key] != data else { return false }
        lastApplied[key] = data
        return true
    }

    /// Triggers a complication timeline reload. Called from background refresh tasks
    /// after a snapshot has already been saved to GlucoseSnapshotStore.
    func triggerComplicationReload() {
        reloadComplications()
    }

    /// Calls `completion` on the main queue with true once the phone can take a live message,
    /// or with false after `timeout`. The Watch only counts the phone as reachable while this
    /// app is in the foreground, so right after a system sheet such as the passcode prompt it
    /// can read as unreachable for a moment with the phone right next to it.
    func whenReachable(timeout: TimeInterval = 3, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let session = WCSession.default
            // Deadline first: if the app was suspended mid-wait, a confirmed command must not
            // go out minutes later.
            if Date() >= deadline {
                completion(false)
            } else if session.activationState == .activated, session.isReachable {
                completion(true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
            }
        }
        DispatchQueue.main.async(execute: check)
    }

    /// Calls `completion` on the main queue with true once WatchConnectivity is activated, or with
    /// false after `timeout`. A notification's action can launch the app before it is.
    func whenActivated(timeout: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if WCSession.default.activationState == .activated {
                completion(true)
            } else if Date() >= deadline {
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
            }
        }
        DispatchQueue.main.async(execute: check)
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionReceiver: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            os_log("WatchSessionReceiver: activation failed — %{public}@", log: watchLog, type: .error, error.localizedDescription)
        } else {
            os_log("WatchSessionReceiver: activation complete — state %d", log: watchLog, type: .debug, activationState.rawValue)
            bootstrapFromApplicationContext(session)
            requestSettings(session)
        }
    }

    /// Asks the phone for current settings so a fresh install does not wait for the
    /// next reading. The reply has the same shape as any other payload.
    private func requestSettings(_ session: WCSession) {
        guard session.isReachable else { return }
        session.sendMessage(["watchRequestSettings": true], replyHandler: { [weak self] reply in
            self?.process(payload: reply, source: "settingsReply")
        }, errorHandler: { error in
            os_log("WatchSessionReceiver: settings request failed — %{public}@", log: watchLog, type: .info, error.localizedDescription)
        })
    }

    /// The Watch's pull-to-refresh: asks the phone to fetch from Nightscout now and applies
    /// its reply; the phone sends what it fetched a few seconds later. When the phone can't
    /// be reached or can't fetch, polls Nightscout directly, which brings BG only.
    /// `completion` runs exactly once, on an arbitrary queue, with whether the phone is fetching.
    func requestRefresh(completion: @escaping (_ phoneIsFetching: Bool) -> Void) {
        let pollNightscout = { WatchNightscoutFetcher.shared.handleRefreshTask { completion(false) } }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            pollNightscout()
            return
        }
        session.sendMessage(["watchRequestRefresh": true], replyHandler: { [weak self] reply in
            self?.process(payload: reply, source: "refreshReply")
            // A phone that doesn't say is assumed to be fetching.
            if reply["refreshing"] as? Bool ?? true {
                completion(true)
            } else {
                pollNightscout()
            }
        }, errorHandler: { error in
            os_log("WatchSessionReceiver: refresh request failed — %{public}@", log: watchLog, type: .info, error.localizedDescription)
            pollNightscout()
        })
    }

    /// Persists phone-owned settings carried in a payload into this device's App Group.
    /// - Returns: true when the payload contained settings.
    @discardableResult
    func applySettings(from payload: [String: Any]) -> Bool {
        guard let data = payload[WatchSettings.payloadKey] as? Data else { return false }
        guard isNewDelivery(data, of: WatchSettings.payloadKey) else { return true }
        do {
            let settings = try WatchSettings.decoded(from: data)
            settings.applyToAppGroup()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: WatchSessionReceiver.settingsRefreshedNotification, object: nil)
            }
            return true
        } catch {
            os_log("WatchSessionReceiver: settings decode failed — %{public}@", log: watchLog, type: .error, error.localizedDescription)
            return false
        }
    }

    /// Persists BG history carried in a payload for the graph and complications.
    func applyHistory(from payload: [String: Any]) {
        guard let data = payload[WatchGlucoseHistory.payloadKey] as? Data,
              isNewDelivery(data, of: WatchGlucoseHistory.payloadKey)
        else { return }
        do {
            let incoming = try WatchGlucoseHistory.decoded(from: data)
            // An old applicationContext must not replace readings the Watch fetched itself.
            let stored = WatchGlucoseHistory.load()
            guard (incoming.points.last?.date ?? 0) >= (stored?.points.last?.date ?? 0), incoming != stored else { return }
            incoming.save()
        } catch {
            os_log("WatchSessionReceiver: history decode failed — %{public}@", log: watchLog, type: .error, error.localizedDescription)
        }
    }

    /// Persists the boluses, SMBs and carbs carried in a payload for the graph.
    func applyTreatments(from payload: [String: Any]) {
        guard let data = payload[WatchTreatmentHistory.payloadKey] as? Data,
              isNewDelivery(data, of: WatchTreatmentHistory.payloadKey)
        else { return }
        do {
            let incoming = try WatchTreatmentHistory.decoded(from: data)
            // Payloads arrive over several channels; an older one must not replace a newer one,
            // and the one already stored needn't be written again. A stored time well ahead of
            // this clock came from a phone clock that was later set back, and must not block
            // updates until real time catches up with it.
            let now = Date().timeIntervalSince1970
            let stored = WatchTreatmentHistory.load()?.generatedAt ?? 0
            guard incoming.generatedAt > (stored <= now + 300 ? stored : 0) else { return }
            incoming.save()
        } catch {
            os_log("WatchSessionReceiver: treatments decode failed — %{public}@", log: watchLog, type: .error, error.localizedDescription)
        }
    }

    /// Hands the phone's alarm state carried in a payload to the alert manager, with the reading it
    /// came with, which the alarm's notification shows before the store has it. Every copy goes, as
    /// each is the phone's word that an alarm is still sounding, which keeps it repeating.
    func applyAlarms(from payload: [String: Any]) {
        guard let data = payload[WatchAlarmState.payloadKey] as? Data else { return }
        do {
            let state = try WatchAlarmState.decoded(from: data)
            let sentAt = payload[WatchAlarmState.sentAtKey] as? TimeInterval ?? 0
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let reading = (payload["snapshot"] as? Data).flatMap { try? decoder.decode(GlucoseSnapshot.self, from: $0) }
            WatchAlertManager.shared.apply(state, sentAt: sentAt, reading: reading)
        } catch {
            os_log("WatchSessionReceiver: alarm state decode failed — %{public}@", log: watchLog, type: .error, error.localizedDescription)
        }
    }

    /// Persists the iPhone's 24-hour stats summary carried in a payload.
    func applyStats(from payload: [String: Any]) {
        guard let data = payload[WatchStatsSummary.payloadKey] as? Data,
              isNewDelivery(data, of: WatchStatsSummary.payloadKey),
              let stats = try? WatchStatsSummary.decoded(from: data)
        else { return }
        stats.save()
    }

    /// Loads a snapshot from the last received applicationContext so the Watch app
    /// has data immediately on launch without waiting for the next transferUserInfo.
    private func bootstrapFromApplicationContext(_ session: WCSession) {
        applySettings(from: session.receivedApplicationContext)
        applyHistory(from: session.receivedApplicationContext)
        applyTreatments(from: session.receivedApplicationContext)
        applyStats(from: session.receivedApplicationContext)
        applyAlarms(from: session.receivedApplicationContext)
        guard let data = session.receivedApplicationContext["snapshot"] as? Data else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(GlucoseSnapshot.self, from: data)
            // The context can be older than what the Watch has fetched itself since.
            let (save, isNewReading) = gate(snapshot)
            guard save else { return }
            beginSave()
            GlucoseSnapshotStore.shared.save(snapshot) { [weak self] in
                os_log("WatchSessionReceiver: bootstrapped snapshot from applicationContext", log: watchLog, type: .debug)
                DispatchQueue.main.async {
                    if isNewReading {
                        self?.reloadComplicationsOnMainThread()
                    }
                    self?.endSave()
                    NotificationCenter.default.post(
                        name: WatchSessionReceiver.snapshotReceivedNotification,
                        object: nil,
                        userInfo: ["snapshot": snapshot]
                    )
                }
            }
        } catch {
            os_log("WatchSessionReceiver: failed to decode applicationContext snapshot — %{public}@", log: watchLog, type: .error, error.localizedDescription)
        }
    }

    /// Handles immediate delivery when Watch app is in foreground (sendMessage path).
    func session(
        _: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        process(payload: message, source: "sendMessage")
    }

    /// Handles queued background delivery (transferUserInfo path).
    func session(
        _: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        process(payload: userInfo, source: "userInfo")
    }

    func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        process(payload: applicationContext, source: "applicationContext")
    }

    // MARK: - Private

    private func process(payload: [String: Any], source: String) {
        applySettings(from: payload)
        applyHistory(from: payload)
        applyTreatments(from: payload)
        applyStats(from: payload)
        applyAlarms(from: payload)

        if let _ = payload["watchLoopReturn"] {
            let title = payload["title"] as? String ?? "Loop Confirmed ✓"
            let body = payload["body"] as? String ?? "Command processed by Loop"
            DispatchQueue.main.async {
                self.showLoopReturnConfirmation(title: title, body: body)
                self.completeHeldTasksIfIdle()
            }
            return
        }

        guard let data = payload["snapshot"] as? Data else {
            os_log("WatchSessionReceiver: %{public}@ — no snapshot key", log: watchLog, type: .debug, source)
            DispatchQueue.main.async { self.completeHeldTasksIfIdle() }
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(GlucoseSnapshot.self, from: data)
            let (save, isNewReading) = gate(snapshot)
            guard save else {
                DispatchQueue.main.async { self.completeHeldTasksIfIdle() }
                return
            }
            os_log("WatchSessionReceiver: %{public}@ snapshot decoded g=%d, saving", log: watchLog, type: .debug, source, Int(snapshot.glucose))
            beginSave()
            GlucoseSnapshotStore.shared.save(snapshot) { [weak self] in
                os_log("WatchSessionReceiver: %{public}@ snapshot saved, reloading complications", log: watchLog, type: .debug, source)
                #if DEBUG
                    // ACK to iPhone so it can detect missed deliveries; a message for every
                    // reading isn't worth the radio time outside debugging.
                    self?.sendAck(for: snapshot)
                #endif
                DispatchQueue.main.async { [weak self] in
                    ChannelDiagnosticsStore.shared.record(.phonePush)
                    if isNewReading {
                        self?.reloadComplicationsOnMainThread()
                    }
                    // Held wakes end only after reloadTimeline() has been called.
                    self?.endSave()
                    NotificationCenter.default.post(
                        name: WatchSessionReceiver.snapshotReceivedNotification,
                        object: nil,
                        userInfo: ["snapshot": snapshot]
                    )
                }
            }
        } catch {
            os_log("WatchSessionReceiver: %{public}@ decode failed — %{public}@", log: watchLog, type: .error, source, error.localizedDescription)
            DispatchQueue.main.async { self.completeHeldTasksIfIdle() }
        }
    }

    /// Whether a snapshot from the phone is worth saving, and whether it is a new reading. Only
    /// a new reading reloads complications, which have a daily budget.
    private func gate(_ snapshot: GlucoseSnapshot) -> (save: Bool, isNewReading: Bool) {
        if ComplicationRefreshCounter.shared.shouldReloadAndRecord(for: snapshot) {
            return (true, true)
        }
        // Nothing stored to compare with: any reading beats none.
        guard let current = GlucoseSnapshotStore.shared.load() else { return (true, true) }
        return (WatchRefreshPolicy.isUpdate(snapshot, of: current), false)
    }

    private func showLoopReturnConfirmation(title: String, body: String) {
        WKInterfaceDevice.current().play(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WKInterfaceDevice.current().play(.success)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "loop-return-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
        os_log("WatchSessionReceiver: Loop return confirmation shown — %{public}@", log: watchLog, type: .info, title)
    }

    #if DEBUG
        private func sendAck(for snapshot: GlucoseSnapshot) {
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            let ack: [String: Any] = ["watchAck": snapshot.updatedAt.timeIntervalSince1970]
            if session.isReachable {
                session.sendMessage(ack, replyHandler: nil, errorHandler: nil)
            } else {
                session.transferUserInfo(ack)
            }
            os_log("WatchSessionReceiver: ACK sent for snapshot at %f", log: watchLog, type: .debug, snapshot.updatedAt.timeIntervalSince1970)
        }
    #endif

    /// Asks WidgetKit to rebuild the complication timelines from the App Group store.
    /// May be called from any thread.
    func reloadComplications() {
        DispatchQueue.main.async { self.reloadComplicationsOnMainThread() }
    }

    private func reloadComplicationsOnMainThread() {
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetKind.glucose)
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetKind.gaugeCorner)
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetKind.stackCorner)
        #if DEBUG
            WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetKind.debug)
        #endif
        os_log("WatchSessionReceiver: complication timelines reload requested", log: watchLog, type: .info)
    }
}
