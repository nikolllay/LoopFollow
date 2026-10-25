// LoopFollow
// WatchTrioOverridesView.swift

import SwiftUI

/// Trio's overrides, as on the phone's Overrides screen: the active one can be cancelled, or one
/// of Trio's presets started.
struct WatchTrioOverridesView: View {
    let snapshot: GlucoseSnapshot?
    /// Closes the remote screens back to the glucose page.
    let onFinished: () -> Void

    private let overrides = WatchRemoteOptions().trio.overrides
    @State private var command: WatchRemoteCommand?

    private var unit: GlucoseSnapshot.Unit { snapshot?.unit ?? .mgdl }

    var body: some View {
        List {
            if let snapshot, snapshot.hasActiveOverride, let name = snapshot.override {
                Section("Active") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.headline)
                        if let endAt = snapshot.overrideEndAt {
                            Text(WatchTempTargetView.remaining(until: endAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        command = WatchRemoteCommand(
                            title: "Cancel override?",
                            details: [name],
                            message: ["watchCmd": "cancelOverride"],
                            noun: "cancellation",
                            sentText: "Override cancellation sent to Trio"
                        )
                    } label: {
                        Label("Cancel Override", systemImage: "xmark.circle")
                    }
                }
            }

            Section("Overrides") {
                if overrides.isEmpty {
                    Text("No overrides found. Add them in Trio.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // By position: nothing stops two overrides sharing a name.
                ForEach(Array(overrides.enumerated()), id: \.offset) { _, override in
                    Button {
                        command = WatchRemoteCommand(
                            title: "Start \(override.name)?",
                            details: details(of: override).map { [$0] } ?? [],
                            message: ["watchCmd": "override", "overrideName": override.name],
                            noun: "override",
                            sentText: "\(override.name) sent to Trio"
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(override.name)
                                .font(.headline)
                            if let details = details(of: override) {
                                Text(details)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Overrides")
        .navigationDestination(isPresented: Binding(get: { command != nil }, set: { if !$0 { command = nil } })) {
            if let command {
                WatchCommandSendView(command: command, onFinished: onFinished)
            }
        }
    }

    /// Its duration, insulin percentage and target, as far as Trio's profile has them.
    private func details(of override: WatchTrioRemote.Override) -> String? {
        var parts: [String] = []
        if let minutes = override.durationMinutes, minutes > 0 { parts.append(WatchFormat.duration(minutes: minutes)) }
        if let percentage = override.percentage { parts.append("\(Int(percentage.rounded()))%") }
        if let target = override.targetMgdl, target > 0 { parts.append(WatchFormat.glucose(mgdl: target, unit: unit)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
