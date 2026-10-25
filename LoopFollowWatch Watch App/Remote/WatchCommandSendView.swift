// LoopFollow
// WatchCommandSendView.swift

import LocalAuthentication
import SwiftUI
import WatchConnectivity
import WatchKit

/// A remote command as `WatchCommandSendView` confirms and sends it.
struct WatchRemoteCommand {
    /// The question on the confirm screen, e.g. "Send meal?".
    let title: String
    /// What it does, a line each.
    var details: [String] = []
    /// A caution under the details.
    var note: String? = nil
    /// The message the phone acts on.
    let message: [String: Any]
    /// Insulin it delivers. Any at all needs the passcode, and counts against the recommended
    /// bolus until the loop reports it.
    var insulin: Double = 0
    /// What it is, for "The meal may still have been sent."
    let noun: String
    /// Shown once it has gone out, e.g. "Meal sent".
    let sentText: String
}

/// Sends one remote command on a single pushed screen: a turn of the crown confirms it, the
/// passcode is asked for when it delivers insulin, and how it went is shown in place. With no
/// sheets or alerts over the remote screens, nothing is left half-presented when they close.
struct WatchCommandSendView: View {
    let command: WatchRemoteCommand
    /// Closes the remote screens.
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stage = Stage.confirm

    private enum Stage {
        case confirm
        /// Waiting for the passcode, which insulin needs.
        case authenticating
        case sending
        case done(Outcome)
    }

    private enum Outcome {
        case sent
        /// Nothing went out; it can be tried again.
        case notSent(String)
        /// It may have gone out: the remote screens then close, so it isn't sent twice.
        case unsure(String)
    }

    private let options = WatchRemoteOptions()

    var body: some View {
        Group {
            switch stage {
            case .confirm:
                CrownConfirmView {
                    summary
                } onConfirm: {
                    start()
                }
            case .authenticating:
                ProgressView("Waiting for passcode…")
            case .sending:
                ProgressView("Sending…")
            case let .done(outcome):
                result(outcome)
            }
        }
        // Once it's on its way the only way out is the result's button.
        .navigationBarBackButtonHidden(!isConfirming)
    }

    private var isConfirming: Bool {
        if case .confirm = stage { return true }
        return false
    }

    private var summary: some View {
        VStack(spacing: 2) {
            Text(command.title)
                .font(.headline)
            ForEach(command.details, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let note = command.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
    }

    private func result(_ outcome: Outcome) -> some View {
        let (icon, color, text, closes): (String, Color, String, Bool) = switch outcome {
        case .sent: ("checkmark.circle.fill", .green, command.sentText, true)
        case let .notSent(text): ("xmark.circle.fill", .red, text, false)
        case let .unsure(text): ("exclamationmark.triangle.fill", .yellow, text, true)
        }
        return ScrollView {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(color)
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(closes ? "Done" : "Back") {
                    if closes { onFinished() } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(closes ? .green : .blue)
            }
        }
    }

    // MARK: - Sending

    private func start() {
        guard command.insulin > 0 else {
            send()
            return
        }
        let context = LAContext()
        var authError: NSError?
        // Fail closed: without a passcode there is no way to confirm who is sending insulin.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            finish(.notSent("Set a passcode on your Apple Watch to send insulin."))
            return
        }
        stage = .authenticating
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Confirm identity to send \(options.insulin(command.insulin))U insulin"
        ) { success, _ in
            DispatchQueue.main.async {
                if success { send() } else { finish(.notSent("Authentication failed or cancelled.\n\nNothing was sent.")) }
            }
        }
    }

    private func send() {
        stage = .sending
        // Right after the crown or the passcode prompt, the phone can read as unreachable for a moment.
        WatchSessionReceiver.shared.whenReachable { reachable in
            guard reachable else {
                finish(.notSent("Phone not reachable. Bring your iPhone closer.\n\nNothing was sent."))
                return
            }
            WCSession.default.sendMessage(command.message) { reply in
                DispatchQueue.main.async { handle(reply) }
            } errorHandler: { error in
                DispatchQueue.main.async {
                    // Once the message has left, no error proves the command wasn't carried out:
                    // even "not reachable" can follow the phone taking it.
                    recordInsulin()
                    let reason = (error as? WCError)?.code == .notReachable
                        ? "Lost connection to the phone."
                        : "Send error: \(error.localizedDescription)"
                    finish(.unsure("\(reason)\n\n\(mayHaveBeenSent)"))
                }
            }
        }
    }

    private func handle(_ reply: [String: Any]) {
        let error = reply["error"] as? String ?? ""
        if reply["totpBlocked"] as? Bool == true {
            finish(.notSent("OTP code already used. Wait up to 30 seconds and try again."))
        } else if reply["success"] as? Bool == true {
            recordInsulin()
            finish(.sent)
        } else if reply["alreadySent"] as? Bool == true {
            // The phone refused a repeat of one that may already have gone out.
            if command.insulin > 0 {
                WatchPendingBolus(units: command.insulin, sentAt: Date()).recordUnlessPending()
            }
            finish(.unsure(error))
        } else if reply["maybeSent"] as? Bool == true {
            // The connection failed after the phone sent it.
            recordInsulin()
            finish(.unsure("\(error.isEmpty ? "Send failed" : error)\n\n\(mayHaveBeenSent)"))
        } else {
            finish(.notSent(error.isEmpty ? "Failed to send" : error))
        }
    }

    private var mayHaveBeenSent: String {
        "The \(command.noun) may still have been sent. Check \(options.system.displayName) before trying again."
    }

    /// Counts insulin that went out, or may have, until the loop reports it, so the recommended
    /// bolus doesn't invite a second dose.
    private func recordInsulin() {
        guard command.insulin > 0 else { return }
        WatchPendingBolus(units: command.insulin, sentAt: Date()).record()
    }

    private func finish(_ outcome: Outcome) {
        if case .sent = outcome {
            WKInterfaceDevice.current().play(.success)
        } else {
            WKInterfaceDevice.current().play(.failure)
        }
        stage = .done(outcome)
    }
}
