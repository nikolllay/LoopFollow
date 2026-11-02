// LoopFollow
// GlucosePage.swift

import Charts
import SwiftUI

/// Main page: one large BG value with trend and delta, IOB and COB, the running override, a two-hour sparkline,
/// and the remote commands in the bottom toolbar.
struct GlucosePage: View {
    let state: WatchState

    @EnvironmentObject private var session: WatchSession
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 2) {
                if let alarm = state.alarm {
                    AlarmBanner(alarm: alarm)
                }
                glucose(now: context.date)
                if !isLuminanceReduced {
                    details
                    overrideLine(now: context.date)
                    Sparkline(state: state, now: context.date)
                        .frame(minHeight: 36)
                }
            }
            .toolbar {
                if !isLuminanceReduced {
                    ToolbarItem(placement: .topBarLeading) {
                        RefreshButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    age(now: context.date)
                }
                if !isLuminanceReduced, let remote = state.remote {
                    ToolbarItemGroup(placement: .bottomBar) {
                        RemoteToolbar(state: state, remote: remote)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func glucose(now: Date) -> some View {
        if let snapshot = state.snapshot {
            let isStale = now.timeIntervalSince(snapshot.updatedAt) >= WatchFormat.staleAfter
            VStack(spacing: -4) {
                // The arrow hangs off the number's trailing edge so the digits, and the delta under them, stay centered.
                Text(WatchFormat.glucose(snapshot.glucose, unit: snapshot.unit))
                    .font(.system(size: 56, weight: .black))
                    .foregroundStyle(WatchFormat.bgColor(snapshot.glucose, lowMgdl: state.lowMgdl, highMgdl: state.highMgdl, colored: state.colorBGText))
                    .strikethrough(isStale, pattern: .solid, color: .red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .overlay(alignment: .trailing) {
                        Text(WatchFormat.trendArrow(snapshot.trend))
                            .font(.system(size: 28, weight: .black))
                            .fixedSize()
                            .alignmentGuide(.trailing) { $0[.leading] - 4 }
                    }
                    // Clear of the battery and reservoir on the left, and evenly on the right, so the BG stays centered.
                    .padding(.horizontal, 44)
                    // The phone's battery and the pump's reservoir, under the refresh button, level with the BG.
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if !isLuminanceReduced {
                            DeviceStatus(snapshot: snapshot)
                                .offset(y: 8)
                        }
                    }
                Text(WatchFormat.delta(snapshot.delta, unit: snapshot.unit))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
        } else {
            Text("No BG data")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    /// Readings come every 5 minutes; the counter turns yellow once one is due.
    private static let agingAfter: TimeInterval = 5 * 60

    /// Age of the reading, counting up every second from 0:00, so a missed reading shows as
    /// 6:34, 6:35…: green, yellow once the next reading is due, red once the reading is stale.
    /// With a marker while the watch fetches on its own or cannot reach the phone.
    @ViewBuilder
    private func age(now: Date) -> some View {
        HStack(spacing: 2) {
            if state.source == .watch {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Fetched by the watch")
            } else if !session.isReachable {
                Image(systemName: "iphone.slash")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("iPhone not reachable")
            }
            if let snapshot = state.snapshot {
                let age = now.timeIntervalSince(snapshot.updatedAt)
                Text(snapshot.updatedAt, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(age >= WatchFormat.staleAfter ? .red : age >= Self.agingAfter ? .yellow : .green)
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var details: some View {
        if let snapshot = state.snapshot {
            if snapshot.isNotLooping {
                Label("Not looping", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if snapshot.iob != nil || snapshot.cob != nil {
                // Large enough to read at a glance; a size smaller, both alike, when the pair doesn't fit.
                ViewThatFits(in: .horizontal) {
                    insulinAndCarbs(snapshot, font: .body)
                    insulinAndCarbs(snapshot, font: .footnote)
                }
            }
        }
    }

    private func insulinAndCarbs(_ snapshot: GlucoseSnapshot, font: Font) -> some View {
        HStack(spacing: 12) {
            if let iob = snapshot.iob {
                Text("\(Image(systemName: "syringe")) \(WatchFormat.iob(iob))")
                    .accessibilityLabel("Insulin on board \(WatchFormat.iob(iob))")
            }
            if let cob = snapshot.cob {
                Text("\(Image(systemName: "fork.knife")) \(WatchFormat.cob(cob))")
                    .accessibilityLabel("Carbs on board \(WatchFormat.cob(cob))")
            }
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
    }

    /// The running override's name and insulin needs.
    @ViewBuilder
    private func overrideLine(now: Date) -> some View {
        let active = state.activeOverride(at: now)
        // The phone's periods end on time; the watch's own fetch only has the snapshot's name.
        if let name = state.overrides == nil ? state.snapshot?.override : active?.name {
            OverrideLine(name: name, percent: active?.percent)
        }
    }
}

/// An override's name and insulin needs, in the green of the overrides button and chart band.
struct OverrideLine: View {
    let name: String
    let percent: Int?

    var body: some View {
        Text("\(Image(systemName: "slider.horizontal.3")) \(name)\(percent.map { "  ·  \($0) %" } ?? "")")
            .font(.footnote)
            .foregroundStyle(.green)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel("Override \(name)\(percent.map { ", insulin needs \($0) percent" } ?? "")")
    }
}

/// Override, treatments and temp target, as in Apple's bottom-toolbar pattern.
private struct RemoteToolbar: View {
    let state: WatchState
    let remote: WatchRemoteConfig
    @EnvironmentObject private var session: WatchSession
    @EnvironmentObject private var navigator: WatchNavigator

    var body: some View {
        Button {
            navigator.push(.overrides)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .tint(state.snapshot?.override != nil ? .green : nil)
        .accessibilityLabel("Overrides")
        .disabled(!session.canSendCommands)

        Button {
            navigator.push(.treatments)
        } label: {
            Image(systemName: "plus")
        }
        .tint(.blue)
        .accessibilityLabel("Meal or bolus")
        .disabled(!session.canSendCommands)

        if remote.kind == .trio {
            Button {
                navigator.push(.tempTargets)
            } label: {
                Image(systemName: "scope")
            }
            .tint(state.snapshot?.tempTargetMgdl != nil ? .green : nil)
            .accessibilityLabel("Temp Target")
            .disabled(!session.canSendCommands)
        } else {
            // Holds the trailing slot so + stays centered.
            Button {} label: {
                Image(systemName: "scope")
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }
}

/// The last two hours in range colors, without axes, scaled to the readings and the range lines.
struct Sparkline: View {
    let state: WatchState
    let now: Date

    var body: some View {
        let start = now.addingTimeInterval(-2 * 3600)
        let readings = state.readings.filter { $0.date >= start }
        let values = readings.map(\.v)
        let bottom = min(values.min() ?? state.lowMgdl, state.lowMgdl) - 10
        let top = max(values.max() ?? state.highMgdl, state.highMgdl) + 10
        Chart {
            RuleMark(y: .value("High", state.highMgdl))
                .foregroundStyle(Color.yellow.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("Low", state.lowMgdl))
                .foregroundStyle(Color.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(readings, id: \.t) { reading in
                PointMark(x: .value("Time", reading.date), y: .value("BG", reading.v))
                    .symbolSize(12)
                    .foregroundStyle(WatchFormat.bgColor(reading.v, lowMgdl: state.lowMgdl, highMgdl: state.highMgdl))
            }
        }
        .chartXScale(domain: start ... now)
        .chartYScale(domain: bottom ... top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

/// The phone's battery, then the pump's reservoir, in small text colored like the delta: the battery red under 20 %,
/// with a green bolt in place of the battery while it charges, as on the phone.
private struct DeviceStatus: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let battery = snapshot.battery {
                (batteryIcon(battery) + Text(" \(Int(battery.rounded()))%"))
                    .foregroundStyle(battery < 20 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Phone battery \(Int(battery.rounded())) percent\(snapshot.batteryIsCharging == true ? ", charging" : "")")
            }
            if let reservoir = snapshot.pumpReservoirU {
                Text("\(Int(reservoir.rounded()))U")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reservoir \(Int(reservoir.rounded())) units")
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func batteryIcon(_ percent: Double) -> Text {
        guard snapshot.batteryIsCharging == true else {
            return Text(Image(systemName: Self.batterySymbol(percent)))
        }
        return Text(Image(systemName: "bolt.fill")).foregroundColor(.green)
    }

    /// A battery that empties with the level, like the system's.
    private static func batterySymbol(_ percent: Double) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Fetches the latest data now: through the phone when it's in reach, otherwise straight from
/// Nightscout or Dexcom. A spinner takes the icon's place while the fetch is under way.
struct RefreshButton: View {
    @EnvironmentObject private var session: WatchSession

    var body: some View {
        Button {
            Task { await session.refreshNow() }
        } label: {
            if session.isRefreshing {
                ProgressView()
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(session.isRefreshing)
        .accessibilityLabel(session.isRefreshing ? "Refreshing" : "Refresh")
    }
}

/// Shown while an alarm is sounding on the phone.
struct AlarmBanner: View {
    let alarm: WatchAlarm
    @EnvironmentObject private var session: WatchSession
    @State private var isSending = false
    @State private var error: String?

    var body: some View {
        Button {
            Task {
                isSending = true
                let reply = await session.send(.snoozeAlarm)
                isSending = false
                error = reply.success ? nil : reply.message
            }
        } label: {
            HStack {
                Image(systemName: "bell.fill")
                VStack(alignment: .leading) {
                    Text(alarm.name)
                        .lineLimit(1)
                    Text(isSending ? "Snoozing…" : "Tap to snooze")
                        .font(.caption2)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(isSending)
        .alert("Snooze failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }
}
