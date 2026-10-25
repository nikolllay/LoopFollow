// LoopFollow
// WatchTempTargetView.swift

import SwiftUI

/// Trio's temp target, as on the phone's Temp Target screen: the active one can be cancelled,
/// a preset saved on the phone started, or a target set here.
struct WatchTempTargetView: View {
    let snapshot: GlucoseSnapshot?
    /// Closes the remote screens back to the glucose page.
    let onFinished: () -> Void

    private let presets = WatchRemoteOptions().trio.tempTargetPresets
    /// Kept from when the screen opened, as the target is held in it.
    @State private var unit: GlucoseSnapshot.Unit
    /// In the display unit.
    @State private var target: Double
    @State private var duration = 60.0
    @State private var command: WatchRemoteCommand?

    init(snapshot: GlucoseSnapshot?, onFinished: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onFinished = onFinished
        let unit = snapshot?.unit ?? .mgdl
        _unit = State(initialValue: unit)
        // Starts from the active target, if there is one, within what can be sent.
        let start = Self.displayValue(snapshot?.activeTempTargetMgdl ?? 100, unit: unit)
        let range = Self.targetRange(unit: unit)
        _target = State(initialValue: min(max(start, range.lowerBound), range.upperBound))
    }

    var body: some View {
        List {
            if let active = snapshot?.activeTempTargetMgdl {
                Section("Active") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(glucose(active))
                            .font(.headline)
                        if let endAt = snapshot?.tempTargetEndAt {
                            Text(Self.remaining(until: endAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        command = WatchRemoteCommand(
                            title: "Cancel temp target?",
                            details: [glucose(active)],
                            message: ["watchCmd": "cancelTempTarget"],
                            noun: "cancellation",
                            sentText: "Temp target cancellation sent to Trio"
                        )
                    } label: {
                        Label("Cancel Temp Target", systemImage: "xmark.circle")
                    }
                }
            }

            if !presets.isEmpty {
                Section("Presets") {
                    // By position: nothing stops two presets sharing a name.
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            command = startCommand(name: preset.name, targetMgdl: preset.targetMgdl, minutes: preset.durationMinutes)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)
                                Text("\(glucose(preset.targetMgdl)) · \(WatchFormat.duration(minutes: preset.durationMinutes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("New Target") {
                WatchAmountRow(
                    title: "Target",
                    value: $target,
                    range: Self.targetRange(unit: unit),
                    step: unit == .mmol ? 0.1 : 1,
                    format: { unit == .mmol ? String(format: "%.1f", $0) : "\(Int($0))" }
                )
                WatchAmountRow(
                    title: "Duration",
                    value: $duration,
                    range: WatchTrioRemote.durationRangeMinutes,
                    step: 5,
                    format: { WatchFormat.duration(minutes: $0) }
                )
                Button {
                    command = startCommand(name: nil, targetMgdl: mgdl(target), minutes: duration)
                } label: {
                    Text("Start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Temp Target")
        .navigationDestination(isPresented: Binding(get: { command != nil }, set: { if !$0 { command = nil } })) {
            if let command {
                WatchCommandSendView(command: command, onFinished: onFinished)
            }
        }
    }

    private func startCommand(name: String?, targetMgdl: Double, minutes: Double) -> WatchRemoteCommand {
        // Whole mg/dL and minutes, as the phone sends them.
        let target = targetMgdl.rounded()
        let minutes = minutes.rounded()
        return WatchRemoteCommand(
            title: name.map { "Start \($0)?" } ?? "Start temp target?",
            details: [glucose(target), "for \(WatchFormat.duration(minutes: minutes))"],
            message: ["watchCmd": "tempTarget", "targetMgdl": target, "durationMinutes": minutes],
            noun: "temp target",
            sentText: "Temp target sent to Trio"
        )
    }

    // MARK: - Units

    /// The phone's 80–200 mg/dL, in the display unit; in mmol/L, the tenths inside it.
    private static func targetRange(unit: GlucoseSnapshot.Unit) -> ClosedRange<Double> {
        let range = WatchTrioRemote.targetRangeMgdl
        guard unit == .mmol else { return range }
        let low = (GlucoseConversion.toMmol(range.lowerBound) * 10).rounded(.up) / 10
        let high = (GlucoseConversion.toMmol(range.upperBound) * 10).rounded(.down) / 10
        return low ... high
    }

    private func mgdl(_ value: Double) -> Double {
        unit == .mmol ? value * GlucoseConversion.mmolToMgDl : value
    }

    private static func displayValue(_ mgdl: Double, unit: GlucoseSnapshot.Unit) -> Double {
        unit == .mmol ? (GlucoseConversion.toMmol(mgdl) * 10).rounded() / 10 : mgdl.rounded()
    }

    private func glucose(_ mgdl: Double) -> String {
        "\(WatchFormat.glucose(mgdl: mgdl, unit: unit)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
    }

    /// "32 min left", "1h 5m left".
    static func remaining(until endAt: TimeInterval) -> String {
        let minutes = max(0, (endAt - Date().timeIntervalSince1970) / 60).rounded(.up)
        return "\(WatchFormat.duration(minutes: minutes)) left"
    }
}

extension GlucoseSnapshot {
    /// The temp target in force: set, and not yet ended.
    var activeTempTargetMgdl: Double? {
        guard let target = tempTargetMgdl else { return nil }
        if let endAt = tempTargetEndAt, endAt <= Date().timeIntervalSince1970 { return nil }
        return target
    }

    /// Whether an override is on: named, and not yet ended.
    var hasActiveOverride: Bool {
        guard let name = override, !name.isEmpty else { return false }
        if let endAt = overrideEndAt, endAt <= Date().timeIntervalSince1970 { return false }
        return true
    }
}
