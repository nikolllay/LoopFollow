// LoopFollow
// WatchCommandDispatcher.swift

import Foundation
import HealthKit

final class WatchCommandDispatcher {
    static let shared = WatchCommandDispatcher()

    private let apnsService = LoopAPNSService()

    /// The last Trio bolus and carb amounts requested from the Watch, each stored as
    /// [amount, sent at]. After a lost reply or a network error nobody can tell whether a
    /// command went out, so the same amount again within `repeatWindow` is refused.
    /// Persisted, so a relaunch of the app doesn't forget it.
    private enum RepeatGuard: String {
        case bolus = "watchRecentTrioBolus"
        case carbs = "watchRecentTrioCarbs"
    }

    private let repeatGuardLock = NSLock()
    static let repeatWindow: TimeInterval = 3 * 60

    private init() {}

    /// The remote Watch commands go through: Trio when Trio Remote Control is the
    /// selected remote type, Loop APNS otherwise. Nil when that remote isn't set up.
    static func activeRemoteSystem() -> WatchRemoteSystem? {
        if Storage.shared.remoteType.value == .trc {
            return isTrioConfigured() ? .trio : nil
        }
        return LoopAPNSService().validateSetup() ? .loop : nil
    }

    /// Mirrors what the phone's Trio remote screen needs: a Trio device plus the
    /// Trio-side fields of the remote settings. APNs credentials are validated on send.
    private static func isTrioConfigured() -> Bool {
        Storage.shared.device.value == "Trio"
            && !Storage.shared.sharedSecret.value.isEmpty
            && !Storage.shared.deviceToken.value.isEmpty
            && !Storage.shared.user.value.isEmpty
            && !Storage.shared.bundleId.value.isEmpty
    }

    func handle(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let cmd = message["watchCmd"] as? String else {
            replyHandler(["success": false, "error": "Unknown command"])
            return
        }
        LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: handling command '\(cmd)'")
        if Storage.shared.remoteType.value == .trc {
            handleTrio(cmd: cmd, message: message, replyHandler: replyHandler)
            return
        }
        switch cmd {
        case "carbs":
            handleCarbs(message: message, replyHandler: replyHandler)
        case "bolus":
            handleBolus(message: message, replyHandler: replyHandler)
        case "override", "preMealOverride":
            handleOverride(message: message, replyHandler: replyHandler)
        default:
            replyHandler(["success": false, "error": "Unrecognised command: \(cmd)"])
        }
    }

    // MARK: - Carbs

    private func handleCarbs(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard apnsService.validateSetup() else {
            replyHandler(["success": false, "error": "LoopAPNS not configured"])
            return
        }
        guard let otp = currentOTP() else {
            replyHandler(["success": false, "error": "OTP unavailable — check QR code in settings"])
            return
        }
        if isTOTPBlocked() {
            replyHandler(["success": false, "totpBlocked": true, "error": "OTP already used — wait up to 30 seconds"])
            return
        }

        let carbsAmount = message["carbsAmount"] as? Double ?? 0
        let absorptionTime = message["absorptionTime"] as? Double ?? 3.0

        guard carbsAmount > 0 else {
            replyHandler(["success": false, "error": "Carbs amount must be greater than 0"])
            return
        }

        let maxCarbs = Storage.shared.maxCarbs.value.doubleValue(for: .gram())
        guard carbsAmount <= maxCarbs else {
            replyHandler(["success": false, "error": "Carbs exceed maximum (\(Int(maxCarbs))g)"])
            return
        }

        let consumedDate = Date().dateUsingCurrentSeconds()
        let payload = LoopAPNSPayload(
            type: .carbs,
            carbsAmount: carbsAmount,
            absorptionTime: absorptionTime,
            consumedDate: consumedDate,
            otp: otp
        )

        apnsService.sendCarbsViaAPNS(payload: payload) { [weak self] ok, err in
            if ok {
                TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: carbs sent — \(carbsAmount)g")
            } else {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: carbs failed — \(err ?? "unknown")")
            }
            replyHandler(["success": ok, "error": err ?? ""])
        }
    }

    // MARK: - Bolus

    private func handleBolus(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard apnsService.validateSetup() else {
            replyHandler(["success": false, "error": "LoopAPNS not configured"])
            return
        }
        guard let otp = currentOTP() else {
            replyHandler(["success": false, "error": "OTP unavailable — check QR code in settings"])
            return
        }
        if isTOTPBlocked() {
            replyHandler(["success": false, "totpBlocked": true, "error": "OTP already used — wait up to 30 seconds"])
            return
        }

        let bolusAmount = message["bolusAmount"] as? Double ?? 0
        guard bolusAmount > 0 else {
            replyHandler(["success": false, "error": "Bolus amount must be greater than 0"])
            return
        }

        let maxBolus = Storage.shared.maxBolus.value.doubleValue(for: .internationalUnit())
        guard bolusAmount <= maxBolus else {
            replyHandler(["success": false, "error": "Bolus exceeds maximum (\(String(format: "%.2f", maxBolus))U)"])
            return
        }

        let payload = LoopAPNSPayload(
            type: .bolus,
            bolusAmount: bolusAmount,
            otp: otp
        )

        apnsService.sendBolusViaAPNS(payload: payload) { [weak self] ok, err in
            if ok {
                TOTPService.shared.markTOTPAsUsed(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: bolus sent — \(bolusAmount)U")
            } else {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: bolus failed — \(err ?? "unknown")")
            }
            replyHandler(["success": ok, "error": err ?? ""])
        }
    }

    // MARK: - Override

    private func handleOverride(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let name = message["overrideName"] as? String, !name.isEmpty else {
            replyHandler(["success": false, "error": "No override name specified"])
            return
        }
        let rawDuration = message["overrideDuration"] as? Double ?? 0
        let duration: TimeInterval? = rawDuration > 0 ? rawDuration : nil

        apnsService.sendOverrideNotification(presetName: name, duration: duration) { ok, err in
            if ok {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: override '\(name)' sent")
            } else {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: override '\(name)' failed — \(err ?? "unknown")")
            }
            replyHandler(["success": ok, "error": err ?? ""])
        }
    }

    // MARK: - Trio

    private func handleTrio(cmd: String, message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard Self.isTrioConfigured() else {
            replyHandler(["success": false, "error": "Trio Remote Control not configured"])
            return
        }
        switch cmd {
        case "carbs":
            handleTrioCarbs(message: message, replyHandler: replyHandler)
        case "bolus":
            handleTrioBolus(message: message, replyHandler: replyHandler)
        default:
            replyHandler(["success": false, "error": "'\(cmd)' is not available for Trio from the Watch"])
        }
    }

    private func handleTrioCarbs(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let carbsAmount = message["carbsAmount"] as? Double ?? 0
        guard carbsAmount > 0 else {
            replyHandler(["success": false, "error": "Carbs amount must be greater than 0"])
            return
        }

        let maxCarbs = Storage.shared.maxCarbs.value.doubleValue(for: .gram())
        guard carbsAmount <= maxCarbs else {
            replyHandler(["success": false, "error": "Carbs exceed maximum (\(Int(maxCarbs))g)"])
            return
        }

        guard claim(.carbs, amount: carbsAmount) else {
            LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio carbs refused — same amount requested within \(Int(Self.repeatWindow))s")
            replyHandler([
                "success": false,
                "alreadySent": true,
                "error": "\(Int(carbsAmount))g of carbs were requested from the Watch moments ago and may have reached Trio. Check Trio; the same amount can be sent again after \(Int(Self.repeatWindow / 60)) minutes.",
            ])
            return
        }

        // Trio applies its own absorption, so the Watch's absorption choice is not sent.
        PushNotificationManager().sendMealPushNotification(
            carbs: HKQuantity(unit: .gram(), doubleValue: carbsAmount),
            protein: HKQuantity(unit: .gram(), doubleValue: 0),
            fat: HKQuantity(unit: .gram(), doubleValue: 0),
            bolusAmount: HKQuantity(unit: .internationalUnit(), doubleValue: 0),
            scheduledTime: nil
        ) { ok, err in
            if ok {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio carbs sent — \(carbsAmount)g")
            } else {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio carbs failed — \(err ?? "unknown")")
            }
            replyHandler(["success": ok, "error": err ?? "", "maybeSent": !ok && Self.mayHaveBeenDelivered(err)])
        }
    }

    private func handleTrioBolus(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let bolusAmount = message["bolusAmount"] as? Double ?? 0
        guard bolusAmount > 0 else {
            replyHandler(["success": false, "error": "Bolus amount must be greater than 0"])
            return
        }

        let maxBolus = Storage.shared.maxBolus.value.doubleValue(for: .internationalUnit())
        guard bolusAmount <= maxBolus else {
            replyHandler(["success": false, "error": "Bolus exceeds maximum (\(String(format: "%.2f", maxBolus))U)"])
            return
        }

        // Reject rather than round: the amount sent must be the one confirmed on the Watch.
        let increment = Storage.shared.bolusIncrement.value.doubleValue(for: .internationalUnit())
        guard Self.isMultiple(bolusAmount, of: increment) else {
            replyHandler(["success": false, "error": "Bolus must be a multiple of \(String(format: "%g", increment))U"])
            return
        }

        guard claim(.bolus, amount: bolusAmount) else {
            LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio bolus refused — same amount requested within \(Int(Self.repeatWindow))s")
            replyHandler([
                "success": false,
                "alreadySent": true,
                "error": "A \(String(format: "%g", bolusAmount))U bolus was requested from the Watch moments ago and may have reached Trio. Check Trio; the same amount can be sent again after \(Int(Self.repeatWindow / 60)) minutes.",
            ])
            return
        }

        PushNotificationManager().sendBolusPushNotification(
            bolusAmount: HKQuantity(unit: .internationalUnit(), doubleValue: bolusAmount)
        ) { ok, err in
            // The record stays even on failure: a network error can follow a push that went out.
            if ok {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio bolus sent — \(bolusAmount)U")
            } else {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio bolus failed — \(err ?? "unknown")")
            }
            replyHandler(["success": ok, "error": err ?? "", "maybeSent": !ok && Self.mayHaveBeenDelivered(err)])
        }
    }

    /// Records a Trio command about to be sent; false when it repeats one requested within `repeatWindow`.
    /// The record stays even if the send fails: a network error can follow a push that went out.
    private func claim(_ kind: RepeatGuard, amount: Double, now: Date = Date()) -> Bool {
        repeatGuardLock.lock()
        defer { repeatGuardLock.unlock() }
        if let stored = UserDefaults.standard.array(forKey: kind.rawValue) as? [Double], stored.count == 2,
           Self.isRepeat(units: amount, of: (units: stored[0], sentAt: Date(timeIntervalSince1970: stored[1])), now: now)
        {
            return false
        }
        UserDefaults.standard.set([amount, now.timeIntervalSince1970], forKey: kind.rawValue)
        return true
    }

    /// Whether a failed push may still have reached APNs. Only a transport failure after the
    /// request left the phone (connection lost, timed out) leaves that open; these are the
    /// messages PushNotificationManager reports for it. Every other failure happens before
    /// sending or is a definite answer from APNs.
    static func mayHaveBeenDelivered(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.hasPrefix("Failed to send push notification:") || error == "Failed to get a valid HTTP response."
    }

    /// Whether `units` repeats `recent` closely enough to be treated as an accidental resend.
    static func isRepeat(units: Double, of recent: (units: Double, sentAt: Date), now: Date) -> Bool {
        abs(units - recent.units) < 1e-6 && now.timeIntervalSince(recent.sentAt) < repeatWindow
    }

    static func isMultiple(_ value: Double, of step: Double) -> Bool {
        guard step > 0 else { return true }
        let steps = value / step
        return abs(steps - steps.rounded()) < 1e-6
    }

    // MARK: - TOTP Helpers

    private func currentOTP() -> String? {
        TOTPGenerator.extractOTPFromURL(Storage.shared.loopAPNSQrCodeURL.value)
    }

    private func isTOTPBlocked() -> Bool {
        TOTPService.shared.isTOTPBlocked(qrCodeURL: Storage.shared.loopAPNSQrCodeURL.value)
    }
}
