// LoopFollow
// WatchRemoteCommandsView.swift

import SwiftUI

/// The remote commands as a grid of tiles, like the phone's remote screen. For Trio: Meal, Bolus,
/// Temp Target and Overrides, the last two outlined in green while one is on.
struct WatchRemoteCommandsView: View {
    let snapshot: GlucoseSnapshot?
    /// Closes the remote screens; called once a command has gone out.
    let onFinished: () -> Void

    private let system = LAAppGroupSettings.watchRemoteSystem()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile("Meal", icon: "fork.knife") {
                    WatchMealCommandView(onFinished: onFinished)
                }
                tile("Bolus", icon: "syringe") {
                    WatchBolusCommandView(snapshot: snapshot, onFinished: onFinished)
                }
                if system == .trio {
                    tile("Temp Target", icon: "scope", isActive: snapshot?.activeTempTargetMgdl != nil) {
                        WatchTempTargetView(snapshot: snapshot, onFinished: onFinished)
                    }
                    tile("Overrides", icon: "slider.horizontal.3", isActive: snapshot?.hasActiveOverride == true) {
                        WatchTrioOverridesView(snapshot: snapshot, onFinished: onFinished)
                    }
                } else {
                    tile("Presets", icon: "list.bullet") {
                        WatchOverridePickerView(onFinished: onFinished)
                    }
                }
            }
        }
        .navigationTitle(system.displayName)
    }

    private func tile(_ title: String, icon: String, isActive: Bool = false, @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink(destination: destination) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: 2.5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isActive ? "On" : "")
    }
}
