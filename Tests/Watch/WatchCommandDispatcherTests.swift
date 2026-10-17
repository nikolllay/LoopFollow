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
}
