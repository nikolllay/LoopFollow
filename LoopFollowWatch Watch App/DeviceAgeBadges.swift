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
    static func color(_ age: DeviceAge, _ coloring: AgeColoring?) -> Color {
        guard let coloring else { return .white }
        switch coloring.level(forDays: age.days) {
        case .ok: return .green
        case .warning: return .yellow
        case .urgent: return .red
        }
    }
}

/// The pump site's and the sensor's age in large type, for a closer look than the badges beside
/// the clock allow; opened by tapping them.
struct DeviceAgeDetailView: View {
    let pumpChangedAt: TimeInterval
    let sensorChangedAt: TimeInterval
    let pumpColoring: AgeColoring?
    let sensorColoring: AgeColoring?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = max(context.date, Date())
            ScrollView {
                VStack(alignment: .leading, spacing: WatchLayout.scaled(14)) {
                    if let pump = DeviceAge(since: pumpChangedAt, now: now) {
                        row(title: "Pump site", icon: "drop.fill", age: pump, coloring: pumpColoring)
                    }
                    if let sensor = DeviceAge(since: sensorChangedAt, now: now) {
                        row(title: "Sensor", icon: "sensor.tag.radiowaves.forward.fill", age: sensor, coloring: sensorColoring)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(title: String, icon: String, age: DeviceAge, coloring: AgeColoring?) -> some View {
        let factor = WatchLayout.textFactor(for: typeSize)
        // All in the age's color, like the badge on the glucose page.
        return VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.system(size: WatchLayout.scaled(17) * factor, weight: .semibold, design: .rounded))
            Text(age.label)
                .font(.system(size: WatchLayout.scaled(40) * factor, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundColor(DeviceAgeBadges.color(age, coloring))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) age \(age.label)")
    }
}
