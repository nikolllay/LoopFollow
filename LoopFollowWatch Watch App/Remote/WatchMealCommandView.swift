// LoopFollow
// WatchMealCommandView.swift

import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

struct WatchMealCommandView: View {
    /// Closes the remote screens back to the glucose page.
    let onFinished: () -> Void

    // Absorption presets: (emoji, hours)
    private let foodPresets: [(String, Double)] = [("🍭", 0.5), ("🌮", 3.0), ("🍕", 5.0)]

    @State private var carbsGrams: Int = 2
    @State private var selectedFood: Int = 1 // default: taco (3 hr)
    @State private var showConfirm = false
    @State private var isSending = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var alertIsSuccess = false
    /// Set once carbs have, or may have, gone out: OK then leaves this screen, so they can't be
    /// sent again by mistake.
    @State private var closeAfterAlert = false
    @FocusState private var amountFocused: Bool

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // Read once, not on every turn of the crown.
    private let maxCarbs = max(5, Int(LAAppGroupSettings.watchMaxCarbs()))
    private let remoteSystem = LAAppGroupSettings.watchRemoteSystem()

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

                // Trio applies its own absorption, so the selector only applies to Loop.
                if remoteSystem == .loop {
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
                            .disabled(isSending)
                        }
                    }

                    Text("\(Int(foodPresets[selectedFood].1 * 60)) min absorption")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Send button
                Button {
                    // Release the crown so turning it to confirm can't change the amount.
                    amountFocused = false
                    showConfirm = true
                } label: {
                    Text("Send Carbs")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || carbsGrams <= 0)
                .sheet(isPresented: $showConfirm) {
                    // The amount confirmed here is the amount sent.
                    let grams = carbsGrams
                    CrownConfirmView(title: "Send \(grams)g?", detail: "Turn the crown to confirm") {
                        sendCarbs(grams: grams)
                    }
                }

                if isSending {
                    ProgressView("Sending…")
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Meal")
        .onAppear {
            amountFocused = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("OK", role: .cancel) {
                if closeAfterAlert { onFinished() }
            }
        }
    }

    private func sendCarbs(grams: Int) {
        // Read at confirmation, like the amount.
        let absorptionHours = foodPresets[selectedFood].1
        isSending = true
        // Right after the confirm sheet closes, the phone can read as unreachable for a moment.
        WatchSessionReceiver.shared.whenReachable { reachable in
            guard reachable else {
                isSending = false
                alertMessage = "Phone not reachable. Bring your iPhone closer.\n\nNothing was sent."
                showAlert = true
                return
            }
            deliverCarbs(grams: grams, absorptionHours: absorptionHours)
        }
    }

    private func deliverCarbs(grams: Int, absorptionHours: Double) {
        let payload: [String: Any] = [
            "watchCmd": "carbs",
            "carbsAmount": Double(grams),
            "absorptionTime": absorptionHours,
        ]
        WCSession.default.sendMessage(payload) { reply in
            DispatchQueue.main.async {
                isSending = false
                let ok = reply["success"] as? Bool ?? false
                let totpBlocked = reply["totpBlocked"] as? Bool ?? false
                if totpBlocked {
                    alertMessage = "OTP code already used. Wait up to 30 seconds and try again."
                } else if ok {
                    closeAfterAlert = true
                    alertMessage = "Carbs sent! (\(grams)g)"
                    scheduleSuccessNotification(grams: grams)
                } else if reply["alreadySent"] as? Bool == true {
                    // The phone refused a repeat of carbs that may already have gone out.
                    closeAfterAlert = true
                    alertMessage = reply["error"] as? String ?? "Failed to send carbs"
                } else if reply["maybeSent"] as? Bool == true {
                    // The connection failed after the phone sent it; Trio may have it.
                    closeAfterAlert = true
                    let error = reply["error"] as? String ?? "Send failed"
                    alertMessage = "\(error)\n\nThe carbs may still have been sent. Check \(remoteSystem.displayName) before trying again."
                } else {
                    alertMessage = reply["error"] as? String ?? "Failed to send carbs"
                }
                showAlert = true
            }
        } errorHandler: { error in
            DispatchQueue.main.async {
                isSending = false
                // Once the message has left, no error proves the carbs weren't sent.
                closeAfterAlert = true
                let reason = (error as? WCError)?.code == .notReachable
                    ? "Lost connection to the phone."
                    : "Send error: \(error.localizedDescription)"
                alertMessage = "\(reason)\n\nThe carbs may still have been sent. Check \(remoteSystem.displayName) before trying again."
                showAlert = true
            }
        }
    }

    private func scheduleSuccessNotification(grams: Int) {
        WKInterfaceDevice.current().play(.success)
        let content = UNMutableNotificationContent()
        content.title = "Carbs Logged ✓"
        content.body = "\(grams)g sent to \(remoteSystem.displayName)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "carbs-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
