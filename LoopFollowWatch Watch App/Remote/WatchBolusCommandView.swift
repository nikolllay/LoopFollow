// LoopFollow
// WatchBolusCommandView.swift

import LocalAuthentication
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

struct WatchBolusCommandView: View {
    let snapshot: GlucoseSnapshot?

    @State private var bolusUnits: Double
    @State private var showConfirm = false
    @State private var isSending = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @FocusState private var amountFocused: Bool

    private let remoteSystem = LAAppGroupSettings.watchRemoteSystem()
    private let step: Double
    private var maxBolus: Double { Self.maxBolus(step: step, system: remoteSystem) }

    /// The loop's recommendation, less any Watch bolus the loop has not seen yet.
    private var recBolus: Double? {
        snapshot.flatMap { Self.adjustedRecommendation(for: $0) }
    }

    private static func adjustedRecommendation(for snapshot: GlucoseSnapshot) -> Double? {
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
    private static func recommendationAge(of snapshot: GlucoseSnapshot?) -> Int? {
        guard let t = snapshot?.loopLastRunAt else { return nil }
        let mins = Int(Date().timeIntervalSince1970 - t) / 60
        return mins < 12 ? mins : nil
    }

    init(snapshot: GlucoseSnapshot?) {
        self.snapshot = snapshot
        let system = LAAppGroupSettings.watchRemoteSystem()
        let step = Self.step(for: system)
        self.step = step
        let maxB = Self.maxBolus(step: step, system: system)
        // Only a fresh recommendation fills the amount in; an older one must be picked from its
        // row, which shows its age.
        let isFresh = (Self.recommendationAge(of: snapshot) ?? .max) < 5
        let rec = isFresh ? snapshot.flatMap { Self.adjustedRecommendation(for: $0) } ?? 0 : 0
        _bolusUnits = State(initialValue: rec > 0 ? Self.prefill(rec, maxBolus: maxB, step: step, system: system) : step)
    }

    /// Loop rounds on its side, so it keeps 0.05U steps. Trio delivers exactly the
    /// amount sent, so it steps in the pump's increment.
    private static func step(for system: WatchRemoteSystem) -> Double {
        system == .trio ? max(0.001, LAAppGroupSettings.watchBolusIncrement()) : 0.05
    }

    private static func maxBolus(step: Double, system: WatchRemoteSystem) -> Double {
        let maxBolus = max(step, LAAppGroupSettings.watchMaxBolus())
        return system == .trio ? maxBolus.roundedDown(toStep: step) : maxBolus
    }

    /// Caps a suggested amount at the max bolus; for Trio it also rounds down to the increment.
    private static func prefill(_ units: Double, maxBolus: Double, step: Double, system: WatchRemoteSystem) -> Double {
        let capped = min(units, maxBolus)
        return system == .trio ? capped.roundedDown(toStep: step) : capped.rounded(toPlaces: 2)
    }

    /// Two decimals, or three for pumps with a 0.025U increment.
    private func formatted(_ units: Double) -> String {
        let hundredths = step * 100
        let digits = abs(hundredths - hundredths.rounded()) < 1e-9 ? 2 : 3
        return String(format: "%.\(digits)f", units)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Recommended bolus tap-to-set row
                if let rec = recBolus, rec > 0, let age = recBolusAge {
                    Button {
                        bolusUnits = Self.prefill(rec, maxBolus: maxBolus, step: step, system: remoteSystem)
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
                    Text("\(formatted(bolusUnits))U")
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

                // Send button
                Button {
                    // Release the crown so turning it to confirm can't change the amount.
                    amountFocused = false
                    showConfirm = true
                } label: {
                    Text("Send Bolus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isSending || bolusUnits <= 0)
                .sheet(isPresented: $showConfirm) {
                    // The amount confirmed here is the amount sent.
                    let units = bolusUnits
                    CrownConfirmView(
                        title: "Send \(formatted(units))U?",
                        detail: "Turn the crown to confirm"
                    ) {
                        authenticateAndSend(units: units)
                    }
                }

                if isSending {
                    ProgressView("Sending…")
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Bolus")
        .onAppear {
            amountFocused = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .onChange(of: bolusUnits) { _, units in
            // Crown values carry floating-point noise; for Trio they must land exactly on the increment.
            let cleaned = remoteSystem == .trio ? units.snapped(toStep: step) : units.rounded(toPlaces: 3)
            if cleaned != units { bolusUnits = cleaned }
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    private func authenticateAndSend(units: Double) {
        let context = LAContext()
        var authError: NSError?
        // Fail closed: without a passcode there is no way to confirm who is sending insulin.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            alertMessage = "Set a passcode on your Apple Watch to send a bolus."
            showAlert = true
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Confirm identity to send \(formatted(units))U insulin"
        ) { success, _ in
            DispatchQueue.main.async {
                if success { sendBolus(units: units) } else {
                    alertMessage = "Authentication failed or cancelled"
                    showAlert = true
                }
            }
        }
    }

    private func sendBolus(units: Double) {
        isSending = true
        // Coming back from the passcode prompt, the phone can read as unreachable for a moment.
        WatchSessionReceiver.shared.whenReachable { reachable in
            guard reachable else {
                isSending = false
                alertMessage = "Phone not reachable. Bring your iPhone closer.\n\nNothing was sent."
                showAlert = true
                return
            }
            deliverBolus(units: units)
        }
    }

    private func deliverBolus(units: Double) {
        let payload: [String: Any] = ["watchCmd": "bolus", "bolusAmount": units]
        WCSession.default.sendMessage(payload) { reply in
            DispatchQueue.main.async {
                isSending = false
                let ok = reply["success"] as? Bool ?? false
                let totpBlocked = reply["totpBlocked"] as? Bool ?? false
                if totpBlocked {
                    alertMessage = "OTP code already used. Wait up to 30 seconds and try again."
                    showAlert = true
                } else if ok {
                    WatchPendingBolus(units: units, sentAt: Date()).record()
                    scheduleSuccessNotification(units: units)
                    alertMessage = "Bolus sent! (\(formatted(units))U)"
                    showAlert = true
                } else if reply["alreadySent"] as? Bool == true {
                    // The phone refused a repeat of a bolus that may already have gone out.
                    WatchPendingBolus(units: units, sentAt: Date()).recordUnlessPending()
                    alertMessage = reply["error"] as? String ?? "Failed to send bolus"
                    showAlert = true
                } else if reply["maybeSent"] as? Bool == true {
                    // The connection failed after the phone sent it; Trio may have it.
                    WatchPendingBolus(units: units, sentAt: Date()).record()
                    let error = reply["error"] as? String ?? "Send failed"
                    alertMessage = "\(error)\n\nThe bolus may still have been sent. Check \(remoteSystem.displayName) before trying again."
                    showAlert = true
                } else {
                    alertMessage = reply["error"] as? String ?? "Failed to send bolus"
                    showAlert = true
                }
            }
        } errorHandler: { error in
            DispatchQueue.main.async {
                isSending = false
                // Once the message has left, no error proves the bolus wasn't sent: even "not
                // reachable" can follow the phone taking it. Count it as given until the loop
                // reports, so the recommendation doesn't invite a second full dose.
                WatchPendingBolus(units: units, sentAt: Date()).record()
                let reason = (error as? WCError)?.code == .notReachable
                    ? "Lost connection to the phone."
                    : "Send error: \(error.localizedDescription)"
                alertMessage = "\(reason)\n\nThe bolus may still have been sent. Check \(remoteSystem.displayName) before trying again."
                showAlert = true
            }
        }
    }

    private func scheduleSuccessNotification(units: Double) {
        WKInterfaceDevice.current().play(.success)
        let content = UNMutableNotificationContent()
        content.title = "Bolus Sent ✓"
        content.body = "\(formatted(units))U sent to \(remoteSystem.displayName)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "bolus-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }

    func snapped(toStep step: Double) -> Double {
        guard step > 0 else { return self }
        return ((self / step).rounded() * step).rounded(toPlaces: 3)
    }

    func roundedDown(toStep step: Double) -> Double {
        guard step > 0 else { return self }
        return ((self / step + 1e-9).rounded(.down) * step).rounded(toPlaces: 3)
    }
}
