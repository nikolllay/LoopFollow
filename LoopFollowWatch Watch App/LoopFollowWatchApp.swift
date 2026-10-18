// LoopFollow
// LoopFollowWatchApp.swift

import OSLog
import SwiftUI
import WatchConnectivity
import WatchKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.loopfollow.watch",
    category: "Watch"
)

@main
struct LoopFollowWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate

    init() {
        WatchSessionReceiver.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - App delegate for background tasks

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchAlertManager.shared.setup()
        WatchAppDelegate.scheduleNextRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refreshTask as WKApplicationRefreshBackgroundTask:
                handleRefresh(refreshTask)

            case let connectivityTask as WKWatchConnectivityRefreshBackgroundTask:
                // Hold the task open — WatchConnectivity will deliver the pending
                // transferUserInfo to session(_:didReceiveUserInfo:) while the app
                // is awake. WatchSessionReceiver completes it once that is saved.
                WatchSessionReceiver.shared.hold(connectivityTask)

            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func handleRefresh(_ task: WKApplicationRefreshBackgroundTask) {
        // receivedApplicationContext always holds the last value the iPhone sent —
        // no active Bluetooth or WKWatchConnectivityRefreshBackgroundTask needed.
        // If it's newer than what's in the file store, persist it and reload complications.
        WatchSessionReceiver.shared.applySettings(from: WCSession.default.receivedApplicationContext)
        WatchSessionReceiver.shared.applyHistory(from: WCSession.default.receivedApplicationContext)
        WatchSessionReceiver.shared.applyTreatments(from: WCSession.default.receivedApplicationContext)
        WatchSessionReceiver.shared.applyStats(from: WCSession.default.receivedApplicationContext)
        let contextSnapshot = Self.decodeContextSnapshot()
        let storeSnapshot = GlucoseSnapshotStore.shared.load()

        let finish = {
            DispatchQueue.main.async {
                WatchAppDelegate.scheduleNextRefresh()
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        // Nightscout can't have anything newer than a reading taken less than a reading
        // interval ago, so the radio stays off.
        let pollNightscout = {
            let newest = GlucoseSnapshotStore.shared.load()?.updatedAt ?? .distantPast
            if Date().timeIntervalSince(newest) < WatchRefreshPolicy.readingInterval {
                finish()
            } else {
                WatchNightscoutFetcher.shared.handleRefreshTask(completion: finish)
            }
        }

        if let ctx = contextSnapshot,
           ctx.updatedAt > (storeSnapshot?.updatedAt ?? .distantPast)
        {
            WatchAlertManager.shared.checkAndAlert(snapshot: ctx)
            // Recorded like any other delivery, so a poll that finds the same reading doesn't
            // count it as new, save a BG-only copy over this one and reload again.
            let isNewReading = ComplicationRefreshCounter.shared.shouldReloadAndRecord(for: ctx)
            GlucoseSnapshotStore.shared.save(ctx) {
                ChannelDiagnosticsStore.shared.record(.watchWake)
                if isNewReading {
                    WatchSessionReceiver.shared.triggerComplicationReload()
                }
                pollNightscout()
            }
        } else {
            // No newer applicationContext — poll NightScout directly.
            pollNightscout()
        }
    }

    static func decodeContextSnapshot() -> GlucoseSnapshot? {
        guard let data = WCSession.default.receivedApplicationContext["snapshot"] as? Data else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GlucoseSnapshot.self, from: data)
        } catch {
            logger.error("WatchAppDelegate: failed to decode applicationContext snapshot — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func scheduleNextRefresh() {
        let now = Date()
        let interval = WatchRefreshPolicy.nextRefreshDelay(
            lastReadingAt: GlucoseSnapshotStore.shared.load()?.updatedAt,
            now: now,
            hour: Calendar.current.component(.hour, from: now)
        )
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: now.addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }
}
