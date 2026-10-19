// LoopFollow
// DeviceAgeTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct DeviceAgeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A change `hours` (plus `extraSeconds`) before `now`.
    private func age(hours: Double, extraSeconds: TimeInterval = 0) -> DeviceAge? {
        DeviceAge(since: now.timeIntervalSince1970 - hours * 3600 - extraSeconds, now: now)
    }

    @Test("#nothing to show without a known change time")
    func unknownChange() {
        #expect(DeviceAge(since: 0, now: now) == nil)
    }

    // MARK: - Label

    @Test("#reads like the phone: whole days and hours")
    func labels() {
        #expect(age(hours: 1)?.label == "0d 1h")
        #expect(age(hours: 15)?.label == "0d 15h")
        #expect(age(hours: 4 * 24 + 5)?.label == "4d 5h")
        #expect(age(hours: 10 * 24 + 12)?.label == "10d 12h")
    }

    @Test("#hours round down, as the phone's do")
    func roundsDown() {
        #expect(age(hours: 1, extraSeconds: 59 * 60)?.label == "0d 1h")
        #expect(age(hours: 0, extraSeconds: 59 * 60)?.label == "0d 0h")
    }

    @Test("#a change time ahead of this clock reads as just changed")
    func changeAhead() {
        #expect(age(hours: -2)?.label == "0d 0h")
    }

    @Test("#days, for the phone's coloring thresholds")
    func days() {
        #expect(age(hours: 3 * 24 + 12)?.days == 3.5)
    }
}
