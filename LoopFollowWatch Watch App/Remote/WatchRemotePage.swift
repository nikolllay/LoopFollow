// LoopFollow
// WatchRemotePage.swift

import SwiftUI

/// A remote command's screen, opened from its tile or a shortcut complication.
enum WatchRemoteScreen: Hashable {
    case meal
    case bolus
    case tempTarget
    case overrides
    /// Loop's override presets.
    case presets
}

/// The remote commands as a page of tiles, the one after the glucose page, like the phone's remote
/// screen. For Trio: Meal, Bolus, Temp Target and Overrides, the last two outlined in green while
/// one is on. A tile opens its command's screen.
struct WatchRemotePage: View {
    let snapshot: GlucoseSnapshot?
    let open: (WatchRemoteScreen) -> Void

    private let system = LAAppGroupSettings.watchRemoteSystem()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile("Meal", icon: "fork.knife", screen: .meal)
                tile("Bolus", icon: "syringe", screen: .bolus)
                if system == .trio {
                    tile("Temp Target", icon: "scope", screen: .tempTarget, isActive: snapshot?.activeTempTargetMgdl != nil)
                    tile("Overrides", icon: "slider.horizontal.3", screen: .overrides, isActive: snapshot?.hasActiveOverride == true)
                } else {
                    tile("Presets", icon: "list.bullet", screen: .presets)
                }
            }
            .padding(.horizontal, WatchLayout.scaled(4))
        }
    }

    private func tile(_ title: String, icon: String, screen: WatchRemoteScreen, isActive: Bool = false) -> some View {
        Button { open(screen) } label: {
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
