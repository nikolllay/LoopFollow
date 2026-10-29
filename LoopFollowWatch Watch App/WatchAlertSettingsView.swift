// LoopFollow
// WatchAlertSettingsView.swift

import SwiftUI

/// The Watch's settings: display options and the delivery diagnostics. Its alarms are the
/// phone's, set up there, and are snoozed from the alarm itself.
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

            Section {
                NavigationLink("Debug") {
                    DiagnosticsView()
                }
            }
        }
        .navigationTitle("Settings")
    }
}
