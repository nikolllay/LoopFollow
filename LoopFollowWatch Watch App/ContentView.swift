// LoopFollow
// ContentView.swift

import Combine
import SwiftUI
import WatchConnectivity
import WatchKit

// MARK: - Root view

struct ContentView: View {
    @StateObject private var model = WatchViewModel()
    @State private var showSettings = false
    @State private var showRemote = false
    @State private var deepLink: WatchDeepLink?
    /// The visible page; 0 is the glucose page.
    @State private var page = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $page) {
            GlucoseView(model: model)
                .tag(0)
                .overlay(alignment: .topTrailing) {
                    // Spaced apart with large tap areas so the icons are easy to hit and hard to mix up.
                    VStack(spacing: 12) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gear")
                                .font(.system(size: GlucoseView.iconSize, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: GlucoseView.iconFrame, height: GlucoseView.iconFrame)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")

                        if model.remoteEnabled {
                            Button { showRemote = true } label: {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: GlucoseView.iconSize, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: GlucoseView.iconFrame, height: GlucoseView.iconFrame)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remote Commands")
                        }

                        // Fetch the latest data now, like pull-to-refresh on the phone.
                        Button { model.requestRefresh() } label: {
                            Group {
                                if model.isRefreshing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: GlucoseView.iconSize, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(width: GlucoseView.iconFrame, height: GlucoseView.iconFrame)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRefreshing)
                        .accessibilityLabel("Refresh")
                    }
                }
                .sheet(isPresented: $showRemote) {
                    NavigationStack { WatchRemoteCommandsView(snapshot: model.snapshot, onFinished: closeRemote) }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack { WatchAlertSettingsView(model: model) }
                }

            GlucoseChartView(
                points: model.history,
                treatments: model.treatments,
                treatmentsAsOf: model.treatmentsAsOf,
                unit: model.snapshot?.unit ?? .mgdl,
                colors: model.bgColors
            )
            .tag(1)

            StatsPageView(stats: model.stats, unit: model.snapshot?.unit ?? .mgdl)
                .tag(2)

            ForEach(model.pages.indices, id: \.self) { idx in
                DataGridPage(slots: model.pages[idx], snapshot: model.snapshot)
                    .tag(3 + idx)
            }
        }
        .tabViewStyle(.page)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Opening the app starts on the glucose page. Raising the wrist after just lowering
            // it (inactive, not background) keeps the page you were looking at.
            if newPhase == .active, oldPhase == .background {
                page = 0
            }
        }
        .sheet(item: $deepLink) { link in
            NavigationStack { remoteView(for: link) }
        }
        .onOpenURL { url in
            // Shortcut complications land on their remote screen; without remote
            // commands configured they simply open the app.
            guard let link = WatchDeepLink(url: url), LAAppGroupSettings.isWatchRemoteEnabled() else { return }
            // Override presets are only wired up for Loop.
            if link == .override, LAAppGroupSettings.watchRemoteSystem() != .loop { return }
            showRemote = false
            showSettings = false
            deepLink = link
        }
        .onAppear {
            model.refresh()
            // Foreground reloads do not count against the complication budget.
            WatchSessionReceiver.shared.reloadComplications()
        }
    }
}

extension ContentView {
    @ViewBuilder
    private func remoteView(for link: WatchDeepLink) -> some View {
        switch link {
        case .bolus: WatchBolusCommandView(snapshot: model.snapshot, onFinished: closeRemote)
        case .meal: WatchMealCommandView(onFinished: closeRemote)
        case .override: WatchOverridePickerView()
        }
    }

    /// Closes the remote screens and shows the glucose page, so after a command has gone out
    /// the send button is out of reach.
    private func closeRemote() {
        showRemote = false
        deepLink = nil
        page = 0
    }
}

// MARK: - View model

final class WatchViewModel: ObservableObject {
    @Published var snapshot: GlucoseSnapshot?
    @Published var selectedSlots: [LiveActivitySlotOption] = LAAppGroupSettings.watchSelectedSlots()
    @Published var showSnoozeSheet = false
    @Published var pendingSnoozeType: WatchAlertType?
    @Published var isSnoozed = false
    @Published var snoozeUntil: Date?
    @Published var hasActiveAlert = false
    @Published var remoteEnabled = LAAppGroupSettings.isWatchRemoteEnabled()
    @Published var history: [WatchGlucoseHistory.Point] = WatchGlucoseHistory.load()?.points ?? []
    @Published var treatments: [WatchTreatmentHistory.Treatment] = WatchTreatmentHistory.load()?.treatments ?? []
    @Published var treatmentsAsOf: TimeInterval? = WatchTreatmentHistory.load()?.asOf
    @Published var stats: WatchStatsSummary? = WatchStatsSummary.load()
    @Published var isRefreshing = false
    /// How BG is colored; kept here so the pages don't read settings on every draw.
    @Published var bgColors = GlucoseColor.Scheme.current()

    private var timer: Timer?
    private var notificationObserver: Any?
    private var snoozeSheetObserver: Any?
    private var settingsObserver: Any?
    private var appSettingsObserver: AnyCancellable?

    init() {
        snapshot = GlucoseSnapshotStore.shared.load()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Nothing here needs the exact second; let watchOS fold this wake in with others.
        timer?.tolerance = 10
        // The Dynamic BG color switch is in the Watch's own settings. Picked up on the next
        // turn of the main queue, once the new value is stored.
        appSettingsObserver = WatchAppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: WatchSessionReceiver.snapshotReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let s = notification.userInfo?["snapshot"] as? GlucoseSnapshot {
                self?.update(snapshot: s)
            } else {
                self?.refresh()
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: WatchSessionReceiver.settingsRefreshedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        snoozeSheetObserver = NotificationCenter.default.addObserver(
            forName: .showSnoozeSheet,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?["alertType"] as? String
            self?.pendingSnoozeType = typeRaw.flatMap { WatchAlertType(rawValue: $0) }
            self?.showSnoozeSheet = true
        }
    }

    deinit {
        timer?.invalidate()
        if let obs = notificationObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = snoozeSheetObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = settingsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// The Watch's pull-to-refresh: asks the phone to fetch from Nightscout now, or polls
    /// Nightscout directly when the phone isn't reachable.
    func requestRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        WKInterfaceDevice.current().play(.click)
        WatchSessionReceiver.shared.requestRefresh { [weak self] phoneIsFetching in
            DispatchQueue.main.async {
                self?.refresh()
                // The phone sends what it fetched about 8 s later; keep the spinner up until then.
                DispatchQueue.main.asyncAfter(deadline: .now() + (phoneIsFetching ? 10 : 1.5)) {
                    self?.isRefreshing = false
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        if let loaded = GlucoseSnapshotStore.shared.load() {
            setIfChanged(\.snapshot, loaded)
        }
        setIfChanged(\.selectedSlots, LAAppGroupSettings.watchSelectedSlots())
        setIfChanged(\.isSnoozed, WatchAlertManager.shared.isGloballySnoozed)
        setIfChanged(\.snoozeUntil, WatchAlertManager.shared.globalSnoozeExpiryDate)
        setIfChanged(\.hasActiveAlert, snapshot.map { WatchAlertManager.shared.hasActiveAlert(for: $0) } ?? false)
        setIfChanged(\.remoteEnabled, LAAppGroupSettings.isWatchRemoteEnabled())
        setIfChanged(\.bgColors, GlucoseColor.Scheme.current())
        loadHistories()
    }

    func update(snapshot: GlucoseSnapshot) {
        setIfChanged(\.snapshot, snapshot)
        setIfChanged(\.selectedSlots, LAAppGroupSettings.watchSelectedSlots())
        setIfChanged(\.hasActiveAlert, WatchAlertManager.shared.hasActiveAlert(for: snapshot))
        loadHistories()
    }

    private func loadHistories() {
        setIfChanged(\.history, WatchGlucoseHistory.load()?.points ?? [])
        let treatmentHistory = WatchTreatmentHistory.load()
        setIfChanged(\.treatments, treatmentHistory?.treatments ?? [])
        setIfChanged(\.treatmentsAsOf, treatmentHistory?.asOf)
        setIfChanged(\.stats, WatchStatsSummary.load())
    }

    /// Every assignment to a published value redraws the pages, the graph included, while the
    /// timer and notifications mostly bring nothing new; so only real changes are assigned.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<WatchViewModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// Slots grouped into pages of 4 for the swipable grid tabs.
    var pages: [[LiveActivitySlotOption]] {
        guard !selectedSlots.isEmpty else { return [] }
        return stride(from: 0, to: selectedSlots.count, by: 4).map {
            Array(selectedSlots[$0 ..< min($0 + 4, selectedSlots.count)])
        }
    }

    func isSelected(_ option: LiveActivitySlotOption) -> Bool {
        selectedSlots.contains(option)
    }

    func toggleSlot(_ option: LiveActivitySlotOption) {
        if let idx = selectedSlots.firstIndex(of: option) {
            selectedSlots.remove(at: idx)
        } else {
            selectedSlots.append(option)
        }
        LAAppGroupSettings.setWatchSelectedSlots(selectedSlots)
    }
}

// MARK: - Page 1: Glucose

struct GlucoseView: View {
    @ObservedObject var model: WatchViewModel

    /// The settings, remote and refresh icons in the top-right column.
    static let iconSize: CGFloat = 18
    static let iconFrame: CGFloat = 34

    var body: some View {
        Group {
            if let s = model.snapshot {
                let bgColor = model.bgColors.color(forMgdl: s.glucose)
                // Ticks every second so the counter's color, and the switch to "--" once the
                // reading is too old, land on time. A tick only works out the freshness; the page
                // redraws when that, the reading or its color changes. An explicit schedule for
                // just those moments didn't fire reliably on watchOS.
                TimelineView(.periodic(from: s.updatedAt, by: 1)) { context in
                    let age = max(context.date, Date()).timeIntervalSince(s.updatedAt)
                    GlucoseReadingView(snapshot: s, freshness: GlucoseFreshness(age: age), bgColor: bgColor)
                        .equatable()
                }
            } else {
                GlucosePlaceholder(caption: Text("No data").font(.caption).foregroundColor(.secondary))
            }
        }
        .sheet(isPresented: $model.showSnoozeSheet, onDismiss: { model.refresh() }) {
            SnoozeView(isPresented: $model.showSnoozeSheet, alertType: model.pendingSnoozeType)
        }
    }
}

/// How old the reading is. The "Updated" counter is green, then yellow, then red, when the page
/// stops showing the number.
private enum GlucoseFreshness {
    case fresh, aging, stale

    /// Readings come every 5 minutes.
    static let agingAfter: TimeInterval = 5 * 60
    /// Too old to show.
    static let staleAfter: TimeInterval = 15 * 60

    init(age: TimeInterval) {
        self = age < Self.agingAfter ? .fresh : age < Self.staleAfter ? .aging : .stale
    }

    var color: Color {
        switch self {
        case .fresh: return .green
        case .aging: return .yellow
        case .stale: return .red
        }
    }
}

/// The glucose page for one reading. Equatable, so the once-a-second tick only redraws it when
/// the reading, its freshness or its color changes.
private struct GlucoseReadingView: View, Equatable {
    let snapshot: GlucoseSnapshot
    let freshness: GlucoseFreshness
    let bgColor: Color

    private static let infoFontSize: CGFloat = 20

    var body: some View {
        if freshness == .stale {
            GlucosePlaceholder(caption: updatedCounter)
        } else {
            reading
        }
    }

    private func infoRow(_ text: Text, color: Color = .white) -> some View {
        text
            .font(.system(size: Self.infoFontSize))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// IOB in yellow and COB in purple, sharing a row; whichever is known.
    private var insulinAndCarbs: Text? {
        let s = snapshot
        let iob = s.iob.map { _ in Text("IOB \(WatchFormat.iob(s)) U").foregroundColor(.yellow) }
        let cob = s.cob.map { _ in Text("COB \(WatchFormat.cob(s)) g").foregroundColor(.purple) }
        switch (iob, cob) {
        case let (iob?, cob?): return Text("\(iob)  \(cob)")
        case let (iob?, nil): return iob
        case let (nil, cob?): return cob
        case (nil, nil): return nil
        }
    }

    /// Time since the reading, counting up every second; it starts again from 0:00 when a new
    /// reading arrives, so a missed reading shows as 6:34, 6:35…
    private var updatedCounter: some View {
        Text("Updated \(Text(snapshot.updatedAt, style: .timer)) ago")
            .font(.system(size: Self.infoFontSize))
            .monospacedDigit()
            .foregroundColor(freshness.color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var reading: some View {
        let s = snapshot
        // Compact rows keep the BG number at full size on the fixed-height page.
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(WatchFormat.glucose(s)) \(WatchFormat.trendArrow(s))")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundColor(bgColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Digits and arrows have no descenders; drop most of the empty space below them.
                .padding(.bottom, -4)

            VStack(alignment: .leading, spacing: 0) {
                infoRow(s.projected != nil
                    ? Text("Δ \(WatchFormat.delta(s))   Proj \(WatchFormat.projected(s))")
                    : Text("Δ \(WatchFormat.delta(s))"))

                if let insulinAndCarbs {
                    infoRow(insulinAndCarbs)
                }

                if !s.basalRate.isEmpty {
                    infoRow(Text("Basal \(WatchFormat.basal(s)) U/h"), color: .blue)
                }

                updatedCounter

                if s.isNotLooping {
                    infoRow(Text("⚠ Loop inactive"), color: .yellow)
                }
            }
        }
        .padding(.leading, 4)
        // Keep clear of the icon column on the right.
        .padding(.trailing, GlucoseView.iconFrame)
    }
}

/// "--" with a caption under it, in the middle of the page.
private struct GlucosePlaceholder<Caption: View>: View {
    let caption: Caption

    var body: some View {
        VStack(spacing: 4) {
            Text("--")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            caption
        }
        // Keep the caption clear of the icon column on the right; equal on the left keeps it centered.
        .padding(.horizontal, GlucoseView.iconFrame)
        // Fill the page so the icon column sits in the corner, not over the placeholder.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data grid page (2×2, up to 4 slots)

struct DataGridPage: View {
    let slots: [LiveActivitySlotOption]
    let snapshot: GlucoseSnapshot?

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            ForEach(0 ..< 4, id: \.self) { i in
                if i < slots.count {
                    let option = slots[i]
                    MetricCell(
                        label: option.gridLabel,
                        value: snapshot.map { WatchFormat.slotValue(option: option, snapshot: $0) } ?? "—"
                    )
                } else {
                    Color.clear.frame(height: 52)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Metric cell

struct MetricCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(8)
    }
}

// MARK: - Settings > Visuals: slot selection checklist

struct SlotSelectionView: View {
    @ObservedObject var model: WatchViewModel

    private var displayedOptions: [LiveActivitySlotOption] {
        LiveActivitySlotOption.allCases.filter { $0 != .none && $0 != .delta && $0 != .projectedBG }
    }

    var body: some View {
        List {
            ForEach(displayedOptions, id: \.self) { option in
                Button(action: { model.toggleSlot(option) }) {
                    HStack {
                        Text(option.displayName)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(
                            systemName: model.isSelected(option)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundColor(model.isSelected(option) ? .green : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Visuals")
    }
}
