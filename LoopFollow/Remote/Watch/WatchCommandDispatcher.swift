// LoopFollow
// WatchCommandDispatcher.swift

import Foundation
import HealthKit

final class WatchCommandDispatcher {
    static let shared = WatchCommandDispatcher()

    private let apnsService = LoopAPNSService()

    /// The last Trio bolus, carbs and meal requested from the Watch, each stored as its amounts
    /// followed by when it was sent. After a lost reply or a network error nobody can tell
    /// whether a command went out, so the same amounts again within `repeatWindow` are refused.
    /// Persisted, so a relaunch of the app doesn't forget it.
    private enum RepeatGuard: String {
        /// Any insulin: a bolus, or a meal's.
        case bolus = "watchRecentTrioBolus"
        case carbs = "watchRecentTrioCarbs"
        /// Carbs, fat, protein and bolus.
        case meal = "watchRecentTrioMeal"
    }

    private typealias Claim = (kind: RepeatGuard, amounts: [Double])

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
        case "meal":
            handleTrioMeal(message: message, replyHandler: replyHandler)
        case "bolus":
            handleTrioBolus(message: message, replyHandler: replyHandler)
        case "tempTarget":
            handleTrioTempTarget(message: message, replyHandler: replyHandler)
        case "cancelTempTarget":
            PushNotificationManager().sendCancelTempTargetPushNotification(completion: trioReply("cancel temp target", replyHandler))
        case "override":
            handleTrioOverride(message: message, replyHandler: replyHandler)
        case "cancelOverride":
            PushNotificationManager().sendCancelOverridePushNotification(completion: trioReply("cancel override", replyHandler))
        default:
            replyHandler(["success": false, "error": "'\(cmd)' is not available for Trio from the Watch"])
        }
    }

    /// Logs a Trio command's outcome and answers the Watch. A failure before anything could have
    /// gone out releases `claims`, so the command can be tried again straight away; any other
    /// outcome keeps them guarded.
    private func trioReply(_ what: String, releasing claims: [Claim] = [], _ replyHandler: @escaping ([String: Any]) -> Void) -> (Bool, String?) -> Void {
        { [self] ok, err in
            let maybeSent = !ok && Self.mayHaveBeenDelivered(err)
            if ok {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio \(what) sent")
            } else {
                LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio \(what) failed — \(err ?? "unknown")")
                if !maybeSent { release(claims) }
            }
            replyHandler(["success": ok, "error": err ?? "", "maybeSent": maybeSent])
        }
    }

    /// The limits of the phone's own Meal screen, which a meal from the Watch must keep to.
    struct TrioMealLimits {
        var maxCarbs: Double
        var maxFat: Double
        var maxProtein: Double
        var maxBolus: Double
        var bolusIncrement: Double
        var withFatProtein: Bool
        var withBolus: Bool

        static func current() -> TrioMealLimits {
            TrioMealLimits(
                maxCarbs: Storage.shared.maxCarbs.value.doubleValue(for: .gram()),
                maxFat: Storage.shared.maxFat.value.doubleValue(for: .gram()),
                maxProtein: Storage.shared.maxProtein.value.doubleValue(for: .gram()),
                maxBolus: Storage.shared.maxBolus.value.doubleValue(for: .internationalUnit()),
                bolusIncrement: Storage.shared.bolusIncrement.value.doubleValue(for: .internationalUnit()),
                withFatProtein: Storage.shared.mealWithFatProtein.value,
                withBolus: Storage.shared.mealWithBolus.value
            )
        }
    }

    /// Why a meal from the Watch can't be sent, or nil when it can. Amounts are sent as they
    /// were confirmed on the Watch, so they're refused rather than rounded.
    static func trioMealError(carbs: Double, fat: Double, protein: Double, bolus: Double, eatenAt: Date?, now: Date, limits: TrioMealLimits) -> String? {
        let grams = [carbs, fat, protein]
        guard (grams + [bolus]).allSatisfy({ $0.isFinite && $0 >= 0 }) else { return "Invalid meal amounts" }
        guard grams.allSatisfy({ $0 == $0.rounded() }) else { return "Carbs, fat and protein must be whole grams" }
        guard grams.contains(where: { $0 > 0 }) else { return "Enter carbs, fat or protein" }
        if carbs > limits.maxCarbs { return "Carbs exceed maximum (\(Int(limits.maxCarbs))g)" }
        if fat > 0 || protein > 0 {
            guard limits.withFatProtein else { return "Fat and protein are turned off in LoopFollow's remote settings" }
            if fat > limits.maxFat { return "Fat exceeds maximum (\(Int(limits.maxFat))g)" }
            if protein > limits.maxProtein { return "Protein exceeds maximum (\(Int(limits.maxProtein))g)" }
        }
        if bolus > 0 {
            guard limits.withBolus else { return "Meal bolus is turned off in LoopFollow's remote settings" }
            if bolus > limits.maxBolus { return "Bolus exceeds maximum (\(String(format: "%.2f", limits.maxBolus))U)" }
            if !isMultiple(bolus, of: limits.bolusIncrement) { return "Bolus must be a multiple of \(String(format: "%g", limits.bolusIncrement))U" }
        }
        if let eatenAt {
            // The time is set when the meal is sent from its form; confirming it and the passcode
            // can take a while after that.
            let minutes = eatenAt.timeIntervalSince(now) / 60
            let range = WatchTrioRemote.mealTimeOffsetRangeMinutes
            guard minutes >= range.lowerBound - 10, minutes <= range.upperBound + 10 else {
                return "Meal time must be within \(Int(range.upperBound / 60)) hours of now"
            }
        }
        return nil
    }

    /// Why a temp target from the Watch can't be sent, or nil when it can.
    static func trioTempTargetError(targetMgdl: Double, durationMinutes: Double) -> String? {
        guard WatchTrioRemote.targetRangeMgdl.contains(targetMgdl), targetMgdl == targetMgdl.rounded() else {
            return "Target must be between \(Int(WatchTrioRemote.targetRangeMgdl.lowerBound)) and \(Int(WatchTrioRemote.targetRangeMgdl.upperBound)) mg/dL"
        }
        guard WatchTrioRemote.durationRangeMinutes.contains(durationMinutes), durationMinutes == durationMinutes.rounded() else {
            return "Duration must be between \(Int(WatchTrioRemote.durationRangeMinutes.lowerBound)) and \(Int(WatchTrioRemote.durationRangeMinutes.upperBound)) minutes"
        }
        return nil
    }

    private func handleTrioMeal(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let carbs = message["carbs"] as? Double ?? 0
        let fat = message["fat"] as? Double ?? 0
        let protein = message["protein"] as? Double ?? 0
        let bolus = message["bolus"] as? Double ?? 0
        let eatenAt = (message["eatenAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

        if let error = Self.trioMealError(carbs: carbs, fat: fat, protein: protein, bolus: bolus, eatenAt: eatenAt, now: Date(), limits: .current()) {
            replyHandler(["success": false, "error": error])
            return
        }

        // A meal's bolus is guarded with the plain ones, so neither can follow the other by mistake.
        var claims: [Claim] = [(.meal, [carbs, fat, protein, bolus])]
        if bolus > 0 { claims.append((.bolus, [bolus])) }
        if let repeated = claim(claims) {
            LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio meal refused — repeats a \(repeated.rawValue) requested within \(Int(Self.repeatWindow))s")
            let what = repeated == .bolus ? "A \(String(format: "%g", bolus))U bolus" : "The same meal"
            replyHandler([
                "success": false,
                "alreadySent": true,
                "error": "\(what) was requested from the Watch moments ago and may have reached Trio. Check Trio; it can be sent again after \(Int(Self.repeatWindow / 60)) minutes.",
            ])
            return
        }

        PushNotificationManager().sendMealPushNotification(
            carbs: HKQuantity(unit: .gram(), doubleValue: carbs),
            protein: HKQuantity(unit: .gram(), doubleValue: protein),
            fat: HKQuantity(unit: .gram(), doubleValue: fat),
            bolusAmount: HKQuantity(unit: .internationalUnit(), doubleValue: bolus),
            scheduledTime: eatenAt,
            completion: trioReply("meal (\(carbs)g carbs, \(fat)g fat, \(protein)g protein, \(bolus)U)", releasing: claims, replyHandler)
        )
    }

    private func handleTrioTempTarget(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let target = message["targetMgdl"] as? Double ?? 0
        let duration = message["durationMinutes"] as? Double ?? 0
        if let error = Self.trioTempTargetError(targetMgdl: target, durationMinutes: duration) {
            replyHandler(["success": false, "error": error])
            return
        }
        PushNotificationManager().sendTempTargetPushNotification(
            target: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: target),
            duration: HKQuantity(unit: .minute(), doubleValue: duration),
            completion: trioReply("temp target \(Int(target)) mg/dL for \(Int(duration)) min", replyHandler)
        )
    }

    private func handleTrioOverride(message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let name = message["overrideName"] as? String ?? ""
        // Only an override Trio has, as the phone's Overrides screen lists them.
        guard let override = ProfileManager.shared.trioOverrides.first(where: { $0.name == name }) else {
            replyHandler(["success": false, "error": "'\(name)' isn't one of Trio's overrides"])
            return
        }
        PushNotificationManager().sendOverridePushNotification(override: override, completion: trioReply("override '\(name)'", replyHandler))
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

        let claims: [Claim] = [(.carbs, [carbsAmount])]
        guard claim(claims) == nil else {
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
            scheduledTime: nil,
            completion: trioReply("carbs \(carbsAmount)g", releasing: claims, replyHandler)
        )
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

        let claims: [Claim] = [(.bolus, [bolusAmount])]
        guard claim(claims) == nil else {
            LogManager.shared.log(category: .apns, message: "WatchCommandDispatcher: Trio bolus refused — same amount requested within \(Int(Self.repeatWindow))s")
            replyHandler([
                "success": false,
                "alreadySent": true,
                "error": "A \(String(format: "%g", bolusAmount))U bolus was requested from the Watch moments ago and may have reached Trio. Check Trio; the same amount can be sent again after \(Int(Self.repeatWindow / 60)) minutes.",
            ])
            return
        }

        PushNotificationManager().sendBolusPushNotification(
            bolusAmount: HKQuantity(unit: .internationalUnit(), doubleValue: bolusAmount),
            completion: trioReply("bolus \(bolusAmount)U", releasing: claims, replyHandler)
        )
    }

    /// Records Trio commands about to be sent, each under its kind. Returns the first that repeats
    /// one requested within `repeatWindow`, recording none of them then. A record stays when the
    /// send fails after it may have gone out: a network error can follow a push that went out.
    private func claim(_ claims: [Claim], now: Date = Date()) -> RepeatGuard? {
        repeatGuardLock.lock()
        defer { repeatGuardLock.unlock() }
        for claim in claims {
            if let stored = UserDefaults.standard.array(forKey: claim.kind.rawValue) as? [Double], let sentAt = stored.last,
               Self.isRepeat(claim.amounts, of: (amounts: Array(stored.dropLast()), sentAt: Date(timeIntervalSince1970: sentAt)), now: now)
            {
                return claim.kind
            }
        }
        for claim in claims {
            UserDefaults.standard.set(claim.amounts + [now.timeIntervalSince1970], forKey: claim.kind.rawValue)
        }
        return nil
    }

    /// Forgets claims whose send failed before anything went out, unless a later command has
    /// taken their place.
    private func release(_ claims: [Claim]) {
        repeatGuardLock.lock()
        defer { repeatGuardLock.unlock() }
        for claim in claims {
            if let stored = UserDefaults.standard.array(forKey: claim.kind.rawValue) as? [Double], let sentAt = stored.last,
               Self.isRepeat(claim.amounts, of: (amounts: Array(stored.dropLast()), sentAt: Date(timeIntervalSince1970: sentAt)), now: Date())
            {
                UserDefaults.standard.removeObject(forKey: claim.kind.rawValue)
            }
        }
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
        isRepeat([units], of: (amounts: [recent.units], sentAt: recent.sentAt), now: now)
    }

    /// Whether `amounts` repeat `recent` closely enough to be treated as an accidental resend.
    static func isRepeat(_ amounts: [Double], of recent: (amounts: [Double], sentAt: Date), now: Date) -> Bool {
        amounts.count == recent.amounts.count
            && zip(amounts, recent.amounts).allSatisfy { abs($0 - $1) < 1e-6 }
            && now.timeIntervalSince(recent.sentAt) < repeatWindow
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
