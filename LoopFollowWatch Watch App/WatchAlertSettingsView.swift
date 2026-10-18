// LoopFollow
// WatchAlertSettingsView.swift

import SwiftUI

/// The Watch's settings: display options only. The Watch's own alerts run on their
/// defaults and are snoozed from the alert itself.
struct WatchAlertSettingsView: View {
    @StateObject private var settings = WatchAppSettings.shared
    @ObservedObject var model: WatchViewModel

    var body: some View {
        List {
            Section("Display") {
                NavigationLink("Visuals") {
                    SlotSelectionView(model: model)
                }

                Toggle("Dynamic BG color", isOn: Binding(
                    get: { settings.dynamicBGColor },
                    set: { settings.dynamicBGColor = $0 }
                ))
            }
        }
        .navigationTitle("Settings")
    }
}
