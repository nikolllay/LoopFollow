// LoopFollow
// WatchMealCommandView.swift

import SwiftUI

/// Logs a meal. For Trio it has the fields of the phone's Meal screen: carbs, and fat, protein
/// and a bolus when the phone's remote settings offer them, plus when it was eaten. Loop takes
/// carbs with an absorption time.
struct WatchMealCommandView: View {
    /// Closes the remote screens back to the glucose page.
    let onFinished: () -> Void

    private let options = WatchRemoteOptions()

    var body: some View {
        if options.system == .trio {
            TrioMealForm(options: options, onFinished: onFinished)
        } else {
            LoopCarbsForm(maxCarbs: Int(options.maxCarbs), onFinished: onFinished)
        }
    }
}

// MARK: - Trio

private struct TrioMealForm: View {
    let options: WatchRemoteOptions
    let onFinished: () -> Void

    @State private var carbs = 0.0
    @State private var fat = 0.0
    @State private var protein = 0.0
    @State private var bolus = 0.0
    /// Minutes from now; 0 is now.
    @State private var timeOffset = 0.0
    @State private var command: WatchRemoteCommand?

    private var trio: WatchTrioRemote { options.trio }

    var body: some View {
        List {
            WatchAmountRow(title: "Carbs", value: $carbs, range: 0 ... options.maxCarbs, step: 1, format: grams)
            if trio.mealWithFatProtein {
                WatchAmountRow(title: "Fat", value: $fat, range: 0 ... max(1, trio.maxFat), step: 1, format: grams)
                WatchAmountRow(title: "Protein", value: $protein, range: 0 ... max(1, trio.maxProtein), step: 1, format: grams)
            }
            if trio.mealWithBolus {
                WatchAmountRow(title: "Bolus", value: $bolus, range: 0 ... options.maxBolus, step: options.bolusStep, format: units)
            }
            WatchAmountRow(
                title: "Time",
                value: $timeOffset,
                range: WatchTrioRemote.mealTimeOffsetRangeMinutes,
                step: 5,
                format: Self.time,
                caption: Self.relative
            )

            Button {
                command = makeCommand()
            } label: {
                Text("Send Meal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .disabled(carbs == 0 && fat == 0 && protein == 0)
        }
        .navigationTitle("Meal")
        .navigationDestination(isPresented: Binding(get: { command != nil }, set: { if !$0 { command = nil } })) {
            if let command {
                WatchCommandSendView(command: command, onFinished: onFinished)
            }
        }
    }

    private func grams(_ value: Double) -> String {
        "\(Int(value))g"
    }

    private func units(_ value: Double) -> String {
        "\(options.insulin(value))U"
    }

    /// "Now", or the time of day.
    private static func time(_ offset: Double) -> String {
        offset == 0 ? "Now" : Date().addingTimeInterval(offset * 60).formatted(date: .omitted, time: .shortened)
    }

    private static func relative(_ offset: Double) -> String? {
        if offset == 0 { return nil }
        let text = WatchFormat.duration(minutes: abs(offset))
        return offset > 0 ? "in \(text)" : "\(text) ago"
    }

    private func makeCommand() -> WatchRemoteCommand {
        let eatenAt = timeOffset == 0 ? nil : Date().addingTimeInterval(timeOffset * 60)
        var message: [String: Any] = ["watchCmd": "meal", "carbs": carbs, "fat": fat, "protein": protein, "bolus": bolus]
        var details = [[("carbs", carbs), ("fat", fat), ("protein", protein)]
            .filter { $0.1 > 0 }
            .map { "\(Int($0.1))g \($0.0)" }
            .joined(separator: ", ")]
        if bolus > 0 { details.append("Bolus \(options.insulin(bolus))U") }
        if let eatenAt {
            message["eatenAt"] = eatenAt.timeIntervalSince1970
            details.append("At \(eatenAt.formatted(date: .omitted, time: .shortened))")
        }
        return WatchRemoteCommand(
            title: "Send meal?",
            details: details,
            // As on the phone: Trio logs the meal for its time, but gives the bolus straight away.
            note: bolus > 0 && eatenAt != nil ? "The bolus is given now" : nil,
            message: message,
            insulin: bolus,
            noun: "meal",
            sentText: "Meal sent to Trio"
        )
    }
}

// MARK: - Loop

private struct LoopCarbsForm: View {
    let maxCarbs: Int
    let onFinished: () -> Void

    // Absorption presets: (emoji, hours)
    private let foodPresets: [(String, Double)] = [("🍭", 0.5), ("🌮", 3.0), ("🍕", 5.0)]

    @State private var carbsGrams: Int = 2
    @State private var selectedFood: Int = 1 // default: taco (3 hr)
    @State private var confirming = false
    @FocusState private var amountFocused: Bool

    /// The crown works on a Double; it moves carbs in 1g steps, like the buttons.
    private var crownCarbs: Binding<Double> {
        Binding(get: { Double(carbsGrams) }, set: { carbsGrams = Int($0.rounded()) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Carbs stepper
                VStack(spacing: 4) {
                    Text("\(carbsGrams)g")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .focusable()
                        .focused($amountFocused)
                        .digitalCrownRotation(
                            crownCarbs,
                            from: 1,
                            through: Double(maxCarbs),
                            by: 1,
                            sensitivity: .low,
                            isContinuous: false,
                            isHapticFeedbackEnabled: true
                        )

                    HStack(spacing: 16) {
                        Button { carbsGrams = max(1, carbsGrams - 1) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)

                        Button { carbsGrams = min(maxCarbs, carbsGrams + 1) } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // Food type selector
                HStack(spacing: 8) {
                    ForEach(0 ..< foodPresets.count, id: \.self) { idx in
                        let (emoji, _) = foodPresets[idx]
                        Button {
                            selectedFood = idx
                        } label: {
                            Text(emoji)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(selectedFood == idx ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.15))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("\(Int(foodPresets[selectedFood].1 * 60)) min absorption")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button {
                    // Release the crown so turning it to confirm can't change the amount.
                    amountFocused = false
                    confirming = true
                } label: {
                    Text("Send Carbs")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(carbsGrams <= 0)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Meal")
        .onAppear { amountFocused = true }
        .navigationDestination(isPresented: $confirming) {
            // The amount and absorption confirmed are the ones sent.
            let absorption = foodPresets[selectedFood].1
            WatchCommandSendView(
                command: WatchRemoteCommand(
                    title: "Send \(carbsGrams)g?",
                    details: ["\(Int(absorption * 60)) min absorption"],
                    message: ["watchCmd": "carbs", "carbsAmount": Double(carbsGrams), "absorptionTime": absorption],
                    noun: "carbs",
                    sentText: "\(carbsGrams)g sent to Loop"
                ),
                onFinished: onFinished
            )
        }
    }
}
