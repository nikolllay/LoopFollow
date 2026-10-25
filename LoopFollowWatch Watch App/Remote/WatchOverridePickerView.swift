// LoopFollow
// WatchOverridePickerView.swift

import SwiftUI

/// Loop's override presets.
struct WatchOverridePickerView: View {
    /// Closes the remote screens back to the glucose page.
    let onFinished: () -> Void

    @State private var presets: [WatchOverridePreset] = []
    @State private var command: WatchRemoteCommand?

    var body: some View {
        List {
            if presets.isEmpty {
                Text("No override presets found.\nConfigure them in your Loop app.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(presets) { preset in
                    Button {
                        command = WatchRemoteCommand(
                            title: "Activate \(preset.name)?",
                            details: [preset.durationDescription],
                            message: [
                                "watchCmd": "override",
                                "overrideName": preset.name,
                                "overrideDuration": preset.durationSeconds,
                            ],
                            noun: "override",
                            sentText: "\(preset.name) sent to Loop"
                        )
                    } label: {
                        HStack {
                            if let symbol = preset.symbol {
                                Text(symbol)
                                    .font(.title3)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(preset.durationDescription)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Presets")
        .onAppear {
            presets = LAAppGroupSettings.watchOverridePresets()
        }
        .navigationDestination(isPresented: Binding(get: { command != nil }, set: { if !$0 { command = nil } })) {
            if let command {
                WatchCommandSendView(command: command, onFinished: onFinished)
            }
        }
    }
}

private extension WatchOverridePreset {
    var durationDescription: String {
        if durationSeconds == 0 { return "Indefinite" }
        let h = Int(durationSeconds) / 3600
        let m = Int(durationSeconds) % 3600 / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}
