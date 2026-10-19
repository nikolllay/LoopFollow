// LoopFollow
// WatchLayout.swift

import SwiftUI
import WatchKit

/// The glucose page is laid out for the 46 mm screen. Its sizes scale to this watch's screen, so
/// every size shows the same page, and its text follows the watch's Text Size as far as it fits.
enum WatchLayout {
    /// This screen against the 46 mm one (208 × 248 pt): about 0.78 on 40 mm, 1 on 46 mm.
    static let scale: CGFloat = {
        let bounds = WKInterfaceDevice.current().screenBounds
        return min(bounds.width / 208, bounds.height / 248)
    }()

    /// A size from the 46 mm layout, on this screen.
    static func scaled(_ points: CGFloat) -> CGFloat {
        points * scale
    }

    /// How much the watch's Text Size enlarges the page's text: not at all at the default, which
    /// is Large on smaller watches and Extra Large on bigger ones, and by at most 30 %, beyond
    /// which the page has no room for it.
    static func textFactor(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.85
        case .small: return 0.9
        case .medium: return 0.95
        case .large, .xLarge: return 1
        case .xxLarge: return 1.1
        case .xxxLarge: return 1.2
        default: return 1.3
        }
    }
}
