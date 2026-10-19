// LoopFollow
// AgeColoringTests.swift

import Foundation
@testable import LoopFollow
import SwiftUI
import Testing

struct AgeColoringTests {
    @Test("#green below the warning, yellow from it, red from the urgent level")
    func levels() {
        let coloring = AgeColoring(warningDays: 3.5, urgentDays: 4)
        #expect(coloring.level(forDays: 3.4) == .ok)
        #expect(coloring.level(forDays: 3.5) == .warning)
        #expect(coloring.level(forDays: 3.9) == .warning)
        #expect(coloring.level(forDays: 4) == .urgent)
    }

    @Test("#a level left unset never applies")
    func unsetLevels() {
        #expect(AgeColoring(warningDays: nil, urgentDays: 4).level(forDays: 3.9) == .ok)
        #expect(AgeColoring(warningDays: 3, urgentDays: nil).level(forDays: 9) == .warning)
        #expect(AgeColoring(warningDays: nil, urgentDays: nil).level(forDays: 9) == .ok)
    }

    @Test("#matches the phone's Info Display coloring for the same ages")
    func matchesPhone() {
        let phone = InfoColoring(enabled: true, warning: 3.5, urgent: 4.5)
        let watch = AgeColoring(warningDays: phone.warning, urgentDays: phone.urgent)
        let expected: [AgeColoring.Level: Color] = [.ok: .green, .warning: .yellow, .urgent: .red]
        for days in stride(from: 0.0, through: 6, by: 0.25) {
            let phoneColor = phone.color(for: days, direction: .above)
            #expect(phoneColor == expected[watch.level(forDays: days)], "\(days) days")
        }
    }
}
