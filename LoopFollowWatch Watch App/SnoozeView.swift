// LoopFollow
// SnoozeView.swift

import SwiftUI

/// The phone's snooze screen, for the alarm sounding: its name, and how long to snooze it, from the
/// lengths the phone offers for it. At 0 it stops it, as the phone's Acknowledge does.
struct SnoozeView: View {
    @Binding var isPresented: Bool
    let sounding: WatchAlarmState.Sounding

    @State private var units: Double

    init(isPresented: Binding<Bool>, sounding: WatchAlarmState.Sounding) {
        _isPresented = isPresented
        self.sounding = sounding
        let range = sounding.snoozeRange
        _units = State(initialValue: Double(min(max(sounding.snoozeUnits, range.lowerBound), range.upperBound)))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(sounding.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if sounding.canChooseSnooze {
                    Text(formattedDuration)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                        .monospacedDigit()

                    Slider(
                        value: $units,
                        in: Double(sounding.snoozeRange.lowerBound) ... Double(sounding.snoozeRange.upperBound),
                        step: Double(max(1, sounding.snoozeStep))
                    )
                    .tint(.orange)
                }

                HStack(spacing: 16) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundColor(.secondary)

                    Button(chosenUnits == 0 ? "Stop" : "Snooze") {
                        WatchAlertManager.shared.snooze(sounding, units: chosenUnits)
                        isPresented = false
                    }
                    .foregroundColor(.orange)
                    .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// The length chosen, within what the phone offers for the alarm.
    private var chosenUnits: Int {
        min(max(Int(units), sounding.snoozeRange.lowerBound), sounding.snoozeRange.upperBound)
    }

    private var formattedDuration: String {
        let mins = Int(sounding.snoozeDuration(units: chosenUnits) / 60)
        if mins < 60 { return "\(mins)m" }
        if mins < 24 * 60 {
            let h = mins / 60, m = mins % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(mins / (24 * 60))d"
    }
}
