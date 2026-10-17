// LoopFollow
// WatchPendingBolusTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct WatchPendingBolusTests {
    private let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var pending: WatchPendingBolus { WatchPendingBolus(units: 1.5, sentAt: sentAt) }

    @Test("#subtracts the bolus while the loop has not run since")
    func subtractsBeforeLoopRuns() {
        let shown = WatchPendingBolus.adjustedRecommendation(
            2.0, pending: pending, loopRanAt: sentAt.addingTimeInterval(-120), now: sentAt.addingTimeInterval(30)
        )
        #expect(shown == 0.5)
    }

    @Test("#stops subtracting once the loop has run after the bolus")
    func clearsAfterLoopRuns() {
        let shown = WatchPendingBolus.adjustedRecommendation(
            0.4, pending: pending, loopRanAt: sentAt.addingTimeInterval(5 * 60), now: sentAt.addingTimeInterval(6 * 60)
        )
        #expect(shown == 0.4)
    }

    @Test("#a loop run moments after sending still counts as pending")
    func loopRunTooSoonStillPending() {
        #expect(pending.isPending(loopRanAt: sentAt.addingTimeInterval(20), now: sentAt.addingTimeInterval(30)))
    }

    @Test("#expires after the maximum age even without a loop run")
    func expires() {
        let now = sentAt.addingTimeInterval(WatchPendingBolus.maximumAge)
        #expect(!pending.isPending(loopRanAt: nil, now: now))
    }

    @Test("#never shows a negative recommendation")
    func neverNegative() {
        let shown = WatchPendingBolus.adjustedRecommendation(1.0, pending: pending, loopRanAt: nil, now: sentAt)
        #expect(shown == 0)
    }

    @Test("#two Watch boluses the loop hasn't seen are both subtracted")
    func subtractsEveryPendingBolus() {
        let second = WatchPendingBolus(units: 1.0, sentAt: sentAt.addingTimeInterval(120))
        let shown = WatchPendingBolus.adjustedRecommendation(
            3.0, pending: [pending, second], loopRanAt: sentAt.addingTimeInterval(-60), now: sentAt.addingTimeInterval(180)
        )
        #expect(shown == 0.5)
    }

    @Test("#a bolus the loop has already seen is not subtracted again")
    func subtractsOnlyUnseen() {
        let later = WatchPendingBolus(units: 1.0, sentAt: sentAt.addingTimeInterval(10 * 60))
        // The loop ran 5 minutes after the first bolus, before the second.
        let shown = WatchPendingBolus.adjustedRecommendation(
            2.0, pending: [pending, later], loopRanAt: sentAt.addingTimeInterval(5 * 60), now: sentAt.addingTimeInterval(11 * 60)
        )
        #expect(shown == 1.0)
    }

    @Test("#no pending bolus leaves the recommendation unchanged")
    func noPending() {
        #expect(WatchPendingBolus.adjustedRecommendation(1.2, pending: nil, loopRanAt: nil, now: sentAt) == 1.2)
    }
}
