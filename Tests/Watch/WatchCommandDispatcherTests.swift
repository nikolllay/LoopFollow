// LoopFollow
// WatchCommandDispatcherTests.swift

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
}
