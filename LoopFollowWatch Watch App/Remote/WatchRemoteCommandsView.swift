// LoopFollow
// WatchRemoteCommandsView.swift

import SwiftUI

struct WatchRemoteCommandsView: View {
    let snapshot: GlucoseSnapshot?
    /// Closes the remote screens; called once a command has gone out.
    let onFinished: () -> Void

    var body: some View {
        List {
            NavigationLink {
                WatchMealCommandView(onFinished: onFinished)
            } label: {
                Label("Meal", systemImage: "fork.knife")
            }

            // Override presets are only wired up for Loop.
            if LAAppGroupSettings.watchRemoteSystem() == .loop {
                NavigationLink {
                    WatchOverridePickerView()
                } label: {
                    Label("Presets", systemImage: "list.bullet")
                }
            }

            NavigationLink {
                WatchBolusCommandView(snapshot: snapshot, onFinished: onFinished)
            } label: {
                Label("Bolus", systemImage: "syringe")
            }
        }
        .navigationTitle("Remote")
    }
}
