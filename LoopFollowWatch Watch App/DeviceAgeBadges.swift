// LoopFollow
// DeviceAgeBadges.swift

import SwiftUI

/// The pump site's and the sensor's age side by side, counting up like the phone's CAGE and
/// SAGE, and colored like those rows of the phone's Info Display. Each is left out while its
/// change time is unknown.
struct DeviceAgeBadges: View {
    /// Last site change and sensor start, Unix epoch seconds; 0 when unknown.
    let pumpChangedAt: TimeInterval
    let sensorChangedAt: TimeInterval
    /// The phone's CAGE and SAGE coloring; nil while it's off.
    let pumpColoring: AgeColoring?
    let sensorColoring: AgeColoring?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if pumpChangedAt > 0 || sensorChangedAt > 0 {
            // A tick a minute, so each hour turns over within a minute of the phone's.
            TimelineView(.everyMinute) { context in
                let now = max(context.date, Date())
                let pump = DeviceAge(since: pumpChangedAt, now: now)
                let sensor = DeviceAge(since: sensorChangedAt, now: now)
                // The largest size at which both fit beside the clock, so long ages or a large
                // Text Size shrink them together instead of running into it.
                ViewThatFits(in: .horizontal) {
                    badges(pump: pump, sensor: sensor, fit: 1)
                    badges(pump: pump, sensor: sensor, fit: 0.9)
                    badges(pump: pump, sensor: sensor, fit: 0.8)
                    badges(pump: pump, sensor: sensor, fit: 0.7)
                }
            }
        }
    }

    private func badges(pump: DeviceAge?, sensor: DeviceAge?, fit: CGFloat) -> some View {
        let size = WatchLayout.scaled(14) * WatchLayout.textFactor(for: typeSize) * fit
        return HStack(spacing: size * 0.4) {
            if let pump {
                badge(icon: "drop.fill", label: pump.label, color: Self.color(pump, pumpColoring), size: size)
                    .accessibilityLabel("Pump age \(pump.label)")
            }
            if let sensor {
                badge(icon: "sensor.tag.radiowaves.forward.fill", label: sensor.label, color: Self.color(sensor, sensorColoring), size: size)
                    .accessibilityLabel("Sensor age \(sensor.label)")
            }
        }
        .fixedSize()
    }

    private func badge(icon: String, label: String, color: Color, size: CGFloat) -> some View {
        HStack(spacing: size * 0.15) {
            Image(systemName: icon)
            Text(label)
                .monospacedDigit()
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .foregroundColor(color)
        .accessibilityElement(children: .ignore)
    }

    /// Like the phone's Info Display: green, yellow, red with the row's coloring on; plain without.
    private static func color(_ age: DeviceAge, _ coloring: AgeColoring?) -> Color {
        guard let coloring else { return .white }
        switch coloring.level(forDays: age.days) {
        case .ok: return .green
        case .warning: return .yellow
        case .urgent: return .red
        }
    }
}
