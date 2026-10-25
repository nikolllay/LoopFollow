// LoopFollow
// WatchAmountEditor.swift

import SwiftUI

/// A form row that shows an amount and opens `WatchAmountEditor` to change it.
struct WatchAmountRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    /// Under the amount in the editor, e.g. "in 15 min" for a time.
    var caption: ((Double) -> String?)? = nil

    var body: some View {
        NavigationLink {
            WatchAmountEditor(title: title, value: $value, range: range, step: step, format: format, caption: caption)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
        }
    }
}

/// Sets one amount: the crown and the − and + buttons move it a step at a time.
struct WatchAmountEditor: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var caption: ((Double) -> String?)? = nil

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                Text(format(value))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let text = caption?(value) {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .focusable()
            .focused($focused)
            .digitalCrownRotation(
                $value,
                from: range.lowerBound,
                through: range.upperBound,
                by: step,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )

            HStack(spacing: 16) {
                Button { value = snap(value - step) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)

                Button { value = snap(value + step) } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(title)
        .onAppear { focused = true }
        .onChange(of: value) { _, newValue in
            // The crown's values carry floating-point noise; amounts land exactly on a step.
            let cleaned = snap(newValue)
            if cleaned != newValue { value = cleaned }
        }
    }

    /// The nearest step from the bottom of the range, within the range: below a top that isn't
    /// on a step, the last step under it.
    private func snap(_ v: Double) -> Double {
        let lower = range.lowerBound
        let snapped = (lower + (max(v, lower) - lower).snapped(toStep: step)).rounded(toPlaces: 3)
        guard snapped > range.upperBound else { return snapped }
        return (lower + (range.upperBound - lower).roundedDown(toStep: step)).rounded(toPlaces: 3)
    }
}
