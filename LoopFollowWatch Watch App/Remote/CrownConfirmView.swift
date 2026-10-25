// LoopFollow
// CrownConfirmView.swift

import SwiftUI
import WatchKit

/// Confirms a command with a deliberate Digital Crown turn, so a stray tap cannot
/// send it. The ring fills as the crown turns; it springs back after a pause.
struct CrownConfirmView<Summary: View>: View {
    /// What is about to be sent.
    @ViewBuilder let summary: Summary
    let onConfirm: () -> Void

    @State private var progress = 0.0
    @State private var confirmed = false
    @State private var lastTurn = Date()
    @FocusState private var crownFocused: Bool

    /// Seconds of inactivity before an unfinished turn resets.
    private var resetAfter: TimeInterval { 2 }

    var body: some View {
        VStack(spacing: 8) {
            summary

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(confirmed ? Color.green : Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: confirmed ? "checkmark" : "digitalcrown.arrow.clockwise")
                        .font(.system(size: 15))
                        .foregroundStyle(confirmed ? .green : .primary)
                }
                .frame(width: 38, height: 38)

                Text(confirmed ? "Confirmed" : "Turn the crown to confirm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .focusable()
        .focused($crownFocused)
        .onAppear { crownFocused = true }
        .digitalCrownRotation(
            $progress,
            from: 0,
            through: 1,
            by: 0.02,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: progress) { _, value in
            guard !confirmed else { return }
            lastTurn = Date()
            if value >= 1 {
                confirmed = true
                WKInterfaceDevice.current().play(.success)
                onConfirm()
            } else {
                scheduleReset()
            }
        }
    }

    private func scheduleReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + resetAfter) {
            guard !confirmed, Date().timeIntervalSince(lastTurn) >= resetAfter else { return }
            withAnimation { progress = 0 }
        }
    }
}
