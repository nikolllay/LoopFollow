// LoopFollow
// WatchBolusCommandView.swift

import SwiftUI

struct WatchBolusCommandView: View {
    let snapshot: GlucoseSnapshot?
    /// Closes the remote screens back to the glucose page.
    let onFinished: () -> Void

    @State private var bolusUnits: Double
    @State private var confirming = false
    @FocusState private var amountFocused: Bool

    // Worked out once, not on every turn of the crown.
    private let options: WatchRemoteOptions
    /// The loop's recommendation, less any Watch bolus the loop has not seen yet.
    private let recBolus: Double?

    static func adjustedRecommendation(for snapshot: GlucoseSnapshot) -> Double? {
        guard let rec = snapshot.recBolus else { return nil }
        return WatchPendingBolus.adjustedRecommendation(
            rec,
            pending: WatchPendingBolus.loadAll(),
            loopRanAt: snapshot.loopLastRunAt.map { Date(timeIntervalSince1970: $0) },
            now: Date()
        )
    }

    private var recBolusAge: Int? { Self.recommendationAge(of: snapshot) }

    /// Minutes since the loop computed the recommendation; nil once it is 12 minutes old,
    /// when it is no longer offered at all.
    static func recommendationAge(of snapshot: GlucoseSnapshot?) -> Int? {
        guard let t = snapshot?.loopLastRunAt else { return nil }
        let mins = Int(Date().timeIntervalSince1970 - t) / 60
        return mins < 12 ? mins : nil
    }

    init(snapshot: GlucoseSnapshot?, onFinished: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onFinished = onFinished
        let options = WatchRemoteOptions()
        let adjustedRec = snapshot.flatMap { Self.adjustedRecommendation(for: $0) }
        self.options = options
        recBolus = adjustedRec
        // Only a fresh recommendation fills the amount in; an older one must be picked from its
        // row, which shows its age.
        let isFresh = (Self.recommendationAge(of: snapshot) ?? .max) < 5
        let rec = isFresh ? adjustedRec ?? 0 : 0
        _bolusUnits = State(initialValue: rec > 0 ? options.bolusPrefill(rec) : options.bolusStep)
    }

    private var step: Double { options.bolusStep }
    private var maxBolus: Double { options.maxBolus }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Recommended bolus tap-to-set row
                if let rec = recBolus, rec > 0, let age = recBolusAge {
                    Button {
                        bolusUnits = options.bolusPrefill(rec)
                    } label: {
                        VStack(spacing: 2) {
                            Text("Rec: \(String(format: "%.2f", rec))U")
                                .font(.headline)
                            Text("\(age)m ago\(age >= 5 ? " ⚠" : "")")
                                .font(.caption2)
                                .foregroundColor(age >= 5 ? .yellow : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                // Bolus amount stepper
                VStack(spacing: 4) {
                    Text("\(options.insulin(bolusUnits))U")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        // The crown adjusts the amount in the same steps as the buttons.
                        .focusable()
                        .focused($amountFocused)
                        .digitalCrownRotation(
                            $bolusUnits,
                            from: step,
                            through: maxBolus,
                            by: step,
                            sensitivity: .low,
                            isContinuous: false,
                            isHapticFeedbackEnabled: true
                        )

                    HStack(spacing: 16) {
                        Button {
                            bolusUnits = max(step, (bolusUnits - step).rounded(toPlaces: 3))
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)

                        Button {
                            bolusUnits = min(maxBolus, (bolusUnits + step).rounded(toPlaces: 3))
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    // Release the crown so turning it to confirm can't change the amount.
                    amountFocused = false
                    confirming = true
                } label: {
                    Text("Send Bolus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(bolusUnits <= 0)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Bolus")
        .onAppear { amountFocused = true }
        .onChange(of: bolusUnits) { _, units in
            // Crown values carry floating-point noise; for Trio they must land exactly on the increment.
            let cleaned = options.system == .trio ? units.snapped(toStep: step) : units.rounded(toPlaces: 3)
            if cleaned != units { bolusUnits = cleaned }
        }
        .navigationDestination(isPresented: $confirming) {
            // The amount confirmed is the amount sent.
            let units = bolusUnits
            WatchCommandSendView(
                command: WatchRemoteCommand(
                    title: "Send \(options.insulin(units))U?",
                    message: ["watchCmd": "bolus", "bolusAmount": units],
                    insulin: units,
                    noun: "bolus",
                    sentText: "\(options.insulin(units))U sent to \(options.system.displayName)"
                ),
                onFinished: onFinished
            )
        }
    }
}
