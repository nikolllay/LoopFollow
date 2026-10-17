// LoopFollow
// WatchRemoteCommandsView.swift

import SwiftUI

struct WatchRemoteCommandsView: View {
    let snapshot: GlucoseSnapshot?

    var body: some View {
        List {
            NavigationLink {
                WatchMealCommandView()
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
                WatchBolusCommandView(snapshot: snapshot)
            } label: {
                Label("Bolus", systemImage: "syringe")
            }
        }
        .navigationTitle("Remote")
    }
}
