// LoopFollow
// WatchCommandDispatcherTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct WatchCommandDispatcherTests {
    @Test("#amounts on the pump's increment are accepted", arguments: [
        (0.05, 0.05), (0.15, 0.05), (1.0, 0.05), (0.3, 0.1), (2.7, 0.1), (0.125, 0.025), (0.975, 0.025),
    ])
    func multiplesAccepted(units: Double, step: Double) {
        #expect(WatchCommandDispatcher.isMultiple(units, of: step))
    }

    @Test("#amounts between increments are rejected", arguments: [
        (0.07, 0.05), (0.12, 0.05), (0.15, 0.1), (1.01, 0.1), (0.13, 0.025),
    ])
    func offStepRejected(units: Double, step: Double) {
        #expect(!WatchCommandDispatcher.isMultiple(units, of: step))
    }

    @Test("#a missing increment does not block a bolus")
    func zeroStepAccepted() {
        #expect(WatchCommandDispatcher.isMultiple(0.37, of: 0))
    }

    @Test("#only transport failures leave delivery open")
    func transportFailuresMayHaveBeenDelivered() {
        #expect(WatchCommandDispatcher.mayHaveBeenDelivered("Failed to send push notification: The network connection was lost."))
        #expect(WatchCommandDispatcher.mayHaveBeenDelivered("Failed to get a valid HTTP response."))
        #expect(!WatchCommandDispatcher.mayHaveBeenDelivered("Missing required fields for command: apnsKey"))
        #expect(!WatchCommandDispatcher.mayHaveBeenDelivered("Bad request. The request was invalid or malformed. BadDeviceToken"))
        #expect(!WatchCommandDispatcher.mayHaveBeenDelivered(nil))
    }

    @Test("#the same amount again within the window is a repeat")
    func sameAmountSoonIsRepeat() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WatchCommandDispatcher.isRepeat(units: 1.5, of: (units: 1.5, sentAt: sent), now: sent.addingTimeInterval(30)))
    }

    @Test("#a different amount, or the same one after the window, is not a repeat")
    func otherAmountOrLaterIsNotRepeat() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = (units: 1.5, sentAt: sent)
        #expect(!WatchCommandDispatcher.isRepeat(units: 1.0, of: recent, now: sent.addingTimeInterval(30)))
        let afterWindow = sent.addingTimeInterval(WatchCommandDispatcher.repeatWindow + 1)
        #expect(!WatchCommandDispatcher.isRepeat(units: 1.5, of: recent, now: afterWindow))
    }

    // MARK: - Trio meal

    private let limits = WatchCommandDispatcher.TrioMealLimits(
        maxCarbs: 100, maxFat: 30, maxProtein: 30, maxBolus: 5, bolusIncrement: 0.05, withFatProtein: true, withBolus: true
    )
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func mealError(
        carbs: Double = 0, fat: Double = 0, protein: Double = 0, bolus: Double = 0,
        eatenAt: Date? = nil, limits: WatchCommandDispatcher.TrioMealLimits? = nil
    ) -> String? {
        WatchCommandDispatcher.trioMealError(
            carbs: carbs, fat: fat, protein: protein, bolus: bolus, eatenAt: eatenAt, now: now, limits: limits ?? self.limits
        )
    }

    @Test("#a meal within the phone's limits goes through")
    func mealWithinLimits() {
        #expect(mealError(carbs: 40, fat: 10, protein: 15, bolus: 2.5) == nil)
        #expect(mealError(fat: 10) == nil)
        #expect(mealError(carbs: 100, eatenAt: now.addingTimeInterval(-180 * 60)) == nil)
        // Confirming and the passcode can take a few minutes after the time was set.
        #expect(mealError(carbs: 100, eatenAt: now.addingTimeInterval(-185 * 60)) == nil)
    }

    @Test("#a meal needs carbs, fat or protein, in whole grams")
    func mealNeedsGrams() {
        #expect(mealError(bolus: 1) != nil)
        #expect(mealError(carbs: 12.5) != nil)
        #expect(mealError(carbs: -5, fat: 10) != nil)
    }

    @Test("#a meal over the phone's maximums is refused")
    func mealOverMaximums() {
        #expect(mealError(carbs: 101) != nil)
        #expect(mealError(carbs: 10, fat: 31) != nil)
        #expect(mealError(carbs: 10, protein: 31) != nil)
        #expect(mealError(carbs: 10, bolus: 5.05) != nil)
    }

    @Test("#a meal bolus off the pump's increment is refused, not rounded")
    func mealBolusOffIncrement() {
        #expect(mealError(carbs: 10, bolus: 1.02) != nil)
    }

    @Test("#fat, protein and a bolus need the phone's settings that offer them")
    func mealFieldsNeedSettings() {
        var off = limits
        off.withFatProtein = false
        off.withBolus = false
        #expect(mealError(carbs: 10, fat: 5, limits: off) != nil)
        #expect(mealError(carbs: 10, bolus: 1, limits: off) != nil)
        #expect(mealError(carbs: 10, limits: off) == nil)
    }

    @Test("#a meal time far from now is refused")
    func mealTimeTooFar() {
        #expect(mealError(carbs: 10, eatenAt: now.addingTimeInterval(4 * 3600)) != nil)
        #expect(mealError(carbs: 10, eatenAt: now.addingTimeInterval(-4 * 3600)) != nil)
    }

    @Test("#the same meal again soon is a repeat; a different one isn't")
    func mealRepeat() {
        let recent = (amounts: [40.0, 10, 0, 2.5], sentAt: now)
        #expect(WatchCommandDispatcher.isRepeat([40, 10, 0, 2.5], of: recent, now: now.addingTimeInterval(30)))
        #expect(!WatchCommandDispatcher.isRepeat([40, 10, 0, 3], of: recent, now: now.addingTimeInterval(30)))
        #expect(!WatchCommandDispatcher.isRepeat([40], of: recent, now: now.addingTimeInterval(30)))
    }

    // MARK: - Trio temp target

    @Test("#temp targets keep to the phone's range and whole minutes")
    func tempTargetLimits() {
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 120, durationMinutes: 60) == nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 80, durationMinutes: 5) == nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 79, durationMinutes: 60) != nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 201, durationMinutes: 60) != nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 120, durationMinutes: 4) != nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 120, durationMinutes: 36 * 60) == nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 120, durationMinutes: 10000) != nil)
        #expect(WatchCommandDispatcher.trioTempTargetError(targetMgdl: 120.5, durationMinutes: 60) != nil)
    }
}
