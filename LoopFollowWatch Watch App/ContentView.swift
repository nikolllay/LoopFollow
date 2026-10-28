// LoopFollow
// ContentView.swift

import Combine
import SwiftUI
import WatchConnectivity
import WatchKit

// MARK: - Root view

/// What shows over the pages. Only one at a time: watchOS presents one sheet, and asking for a
/// second while another is up, or while one is closing, can leave a screen that takes no taps.
private enum RootSheet: Identifiable, Hashable {
    /// A remote command's screen, from its tile or a shortcut complication.
    case command(WatchRemoteScreen)
    case deviceAges
    case snooze

    var id: Self { self }
}

/// The pages, left to right: glucose, then the remote commands when they're set up, the
/// treatments, the graph, the stats, settings, and the data pages.
private enum Page {
    static let glucose = 0
    static let remote = 1
    static let treatments = 2
    static let graph = 3
    static let stats = 4
    static let settings = 5
    static let firstData = 6
}

struct ContentView: View {
    @StateObject private var model = WatchViewModel()
    @State private var sheet: RootSheet?
    /// The visible page, from `Page`.
    @State private var page = Page.glucose
    @Environment(\.scenePhase) private var scenePhase

    /// Last site change and sensor start, Unix epoch seconds; 0 when unknown.
    private var pumpChangedAt: TimeInterval { model.snapshot?.cageInsertTime ?? 0 }
    private var sensorChangedAt: TimeInterval { model.snapshot?.sageInsertTime ?? 0 }

    var body: some View {
        TabView(selection: $page) {
            GlucoseView(model: model)
                .tag(Page.glucose)

            if model.remoteEnabled {
                WatchRemotePage(snapshot: model.snapshot) { sheet = .command($0) }
                    .tag(Page.remote)
            }

            WatchTreatmentsPage(unit: model.snapshot?.unit ?? .mgdl, isVisible: page == Page.treatments)
                .tag(Page.treatments)

            GlucoseChartView(
                points: model.history,
                treatments: model.treatments,
                treatmentsAsOf: model.treatmentsAsOf,
                unit: model.snapshot?.unit ?? .mgdl,
                colors: model.bgColors
            )
            .tag(Page.graph)

            StatsPageView(stats: model.stats, unit: model.snapshot?.unit ?? .mgdl)
                .tag(Page.stats)

            NavigationStack { WatchAlertSettingsView(model: model) }
                .tag(Page.settings)

            ForEach(model.pages.indices, id: \.self) { idx in
                DataGridPage(slots: model.pages[idx], snapshot: model.snapshot)
                    .tag(Page.firstData + idx)
            }
        }
        .tabViewStyle(.page)
        // On the glucose page, the pump and sensor ages sit left of the clock, centered in its
        // row: space the page doesn't otherwise use, whose height differs between watch sizes.
        // Tapping them shows them larger.
        .overlay(alignment: .topLeading) {
            if page == Page.glucose, pumpChangedAt > 0 || sensorChangedAt > 0 {
                GeometryReader { geo in
                    Button { sheet = .deviceAges } label: {
                        DeviceAgeBadges(
                            pumpChangedAt: pumpChangedAt,
                            sensorChangedAt: sensorChangedAt,
                            pumpColoring: model.pumpAgeColoring,
                            sensorColoring: model.sensorAgeColoring
                        )
                        // Clear of the clock, which takes a little over the right third of the row.
                        .frame(maxWidth: geo.size.width * 0.6, alignment: .leading)
                        .frame(height: geo.safeAreaInsets.top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows them larger")
                    .padding(.leading, WatchLayout.scaled(16))
                    .offset(y: -geo.safeAreaInsets.top)
                }
            }
        }
        // Every sheet is presented here, at the root, rather than from inside a page.
        .sheet(item: $sheet, onDismiss: {
            // Picks up a snooze just set, among other things.
            model.refresh()
            // A snooze asked for while a remote screen was open, now that it has closed.
            if model.showSnoozeSheet, sheet == nil { sheet = .snooze }
        }) { shown in
            switch shown {
            case let .command(screen):
                NavigationStack { remoteView(for: screen) }
            case .deviceAges:
                NavigationStack {
                    DeviceAgeDetailView(
                        pumpChangedAt: pumpChangedAt,
                        sensorChangedAt: sensorChangedAt,
                        pumpColoring: model.pumpAgeColoring,
                        sensorColoring: model.sensorAgeColoring
                    )
                }
            case .snooze:
                SnoozeView(isPresented: snoozeShown, alertType: model.pendingSnoozeType)
            }
        }
        // An alert's Snooze action asks for the snooze sheet. It takes the place of the ages, but
        // waits for a remote screen to close, so a command on its way isn't cut off before its
        // result shows. Checked on appear too, for a Snooze tap that opened the app.
        .onChange(of: model.showSnoozeSheet, initial: true) { _, show in
            guard show else { return }
            if case .command = sheet { return }
            sheet = .snooze
        }
        .onChange(of: sheet) { old, new in
            // The snooze sheet has closed, or a shortcut has taken its place.
            if old == .snooze, new != .snooze { model.showSnoozeSheet = false }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Opening the app starts on the glucose page. Raising the wrist after just lowering
            // it (inactive, not background) keeps the page you were looking at.
            if newPhase == .active, oldPhase == .background {
                page = Page.glucose
            }
            // An alarm may have been snoozed or stopped from its notification meanwhile.
            if newPhase == .active {
                model.refresh()
            }
        }
        .onOpenURL { url in
            // Shortcut complications land on their remote screen; without remote
            // commands configured they simply open the app.
            guard let link = WatchDeepLink(url: url), LAAppGroupSettings.isWatchRemoteEnabled() else { return }
            switch link {
            case .bolus: sheet = .command(.bolus)
            case .meal: sheet = .command(.meal)
            case .override:
                // The override shortcut opens Loop's presets; Trio's overrides are on the remote page.
                guard LAAppGroupSettings.watchRemoteSystem() == .loop else { return }
                sheet = .command(.presets)
            }
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
    private func remoteView(for screen: WatchRemoteScreen) -> some View {
        switch screen {
        case .meal: WatchMealCommandView(onFinished: closeRemote)
        case .bolus: WatchBolusCommandView(snapshot: model.snapshot, onFinished: closeRemote)
        case .tempTarget: WatchTempTargetView(snapshot: model.snapshot, onFinished: closeRemote)
        case .overrides: WatchTrioOverridesView(snapshot: model.snapshot, onFinished: closeRemote)
        case .presets: WatchOverridePickerView(onFinished: closeRemote)
        }
    }

    private var snoozeShown: Binding<Bool> {
        Binding(get: { sheet == .snooze }, set: { if !$0, sheet == .snooze { sheet = nil } })
    }

    /// Closes the remote screen and shows the glucose page, so after a command has gone out
    /// the send button is out of reach.
    private func closeRemote() {
        sheet = nil
        page = Page.glucose
    }
}

// MARK: - View model

final class WatchViewModel: ObservableObject {
    @Published var snapshot: GlucoseSnapshot?
    @Published var selectedSlots: [LiveActivitySlotOption] = LAAppGroupSettings.watchSelectedSlots()
    @Published var showSnoozeSheet = false
    @Published var pendingSnoozeType: WatchAlertType?
    /// What the glucose page offers for the Watch's alerts.
    @Published var snoozeStatus = WatchAlertManager.SnoozeStatus.none
    @Published var remoteEnabled = LAAppGroupSettings.isWatchRemoteEnabled()
    @Published var history: [WatchGlucoseHistory.Point] = WatchGlucoseHistory.load()?.points ?? []
    @Published var treatments: [WatchTreatmentHistory.Treatment] = WatchTreatmentHistory.load()?.treatments ?? []
    @Published var treatmentsAsOf: TimeInterval? = WatchTreatmentHistory.load()?.asOf
    @Published var stats: WatchStatsSummary? = WatchStatsSummary.load()
    @Published var isRefreshing = false
    /// How BG is colored; kept here so the pages don't read settings on every draw.
    @Published var bgColors = GlucoseColor.Scheme.current()
    /// The loop's recommended bolus as the Bolus screen offers it; nil when it doesn't.
    @Published var recommendedBolus: Double?
    /// The phone's CAGE and SAGE coloring, for the pump and sensor ages.
    @Published var pumpAgeColoring = LAAppGroupSettings.watchPumpAgeColoring()
    @Published var sensorAgeColoring = LAAppGroupSettings.watchSensorAgeColoring()

    private var timer: Timer?
    private var notificationObserver: Any?
    private var snoozeSheetObserver: Any?
    private var settingsObserver: Any?
    private var alarmsObserver: Any?
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
        // An alarm can start, end, or be stopped or snoozed without a new reading being saved.
        alarmsObserver = NotificationCenter.default.addObserver(
            forName: .watchAlarmsChanged,
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
        if let obs = alarmsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// Shortest time the refresh spinner shows, so a quick answer still reads as one.
    private static let minimumSpin: TimeInterval = 0.6

    /// The Watch's pull-to-refresh: asks the phone to fetch from Nightscout now, or polls
    /// Nightscout directly when the phone isn't reachable.
    func requestRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        WKInterfaceDevice.current().play(.click)
        let started = Date()
        WatchSessionReceiver.shared.requestRefresh { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
                // The spinner stops once the answer is on screen. What the phone fetches after
                // its reply arrives on its own a few seconds later and updates the page then.
                let left = Self.minimumSpin - Date().timeIntervalSince(started)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, left)) {
                    self?.isRefreshing = false
                }
            }
        }
    }

    func refresh() {
        if let loaded = GlucoseSnapshotStore.shared.load() {
            setIfChanged(\.snapshot, loaded)
        }
        // Also after a bolus from the Watch, which the remote screens record as they close.
        setIfChanged(\.recommendedBolus, snapshot.flatMap { Self.recommendation(for: $0) })
        setIfChanged(\.selectedSlots, LAAppGroupSettings.watchSelectedSlots())
        setIfChanged(\.snoozeStatus, WatchAlertManager.shared.snoozeStatus(for: snapshot))
        setIfChanged(\.remoteEnabled, LAAppGroupSettings.isWatchRemoteEnabled())
        setIfChanged(\.bgColors, GlucoseColor.Scheme.current())
        setIfChanged(\.pumpAgeColoring, LAAppGroupSettings.watchPumpAgeColoring())
        setIfChanged(\.sensorAgeColoring, LAAppGroupSettings.watchSensorAgeColoring())
        loadHistories()
    }

    func update(snapshot: GlucoseSnapshot) {
        setIfChanged(\.snapshot, snapshot)
        setIfChanged(\.recommendedBolus, Self.recommendation(for: snapshot))
        setIfChanged(\.selectedSlots, LAAppGroupSettings.watchSelectedSlots())
        setIfChanged(\.snoozeStatus, WatchAlertManager.shared.snoozeStatus(for: snapshot))
        loadHistories()
    }

    private func loadHistories() {
        setIfChanged(\.history, WatchGlucoseHistory.load()?.points ?? [])
        let treatmentHistory = WatchTreatmentHistory.load()
        setIfChanged(\.treatments, treatmentHistory?.treatments ?? [])
        setIfChanged(\.treatmentsAsOf, treatmentHistory?.asOf)
        setIfChanged(\.stats, WatchStatsSummary.load())
    }

    /// As the Bolus screen offers it: less any Watch bolus the loop hasn't seen yet, and only while
    /// the loop's last run is recent.
    private static func recommendation(for snapshot: GlucoseSnapshot) -> Double? {
        guard WatchBolusCommandView.recommendationAge(of: snapshot) != nil else { return nil }
        return WatchBolusCommandView.adjustedRecommendation(for: snapshot)
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
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Room left and right of the page's text, clear of the screen's rounded edge.
    static let sideMargin = WatchLayout.scaled(10)

    var body: some View {
        Group {
            if let s = model.snapshot {
                let bgColor = model.bgColors.color(forMgdl: s.glucose)
                // Colored like the BG, so a predicted low or high stands out.
                let projectedColor = s.projected.map { model.bgColors.color(forMgdl: $0) } ?? .white
                // During an alarm the rows give up a little of their size to the snooze button.
                let textFactor = WatchLayout.textFactor(for: typeSize) * (model.snoozeStatus == .active ? 0.9 : 1)
                // Ticks every second so the counter's color, and the switch to "--" once the
                // reading is too old, land on time. A tick only works out the freshness; the page
                // redraws when that, the reading or its color changes. An explicit schedule for
                // just those moments didn't fire reliably on watchOS.
                TimelineView(.periodic(from: s.updatedAt, by: 1)) { context in
                    let age = max(context.date, Date()).timeIntervalSince(s.updatedAt)
                    GlucoseReadingView(
                        snapshot: s,
                        freshness: GlucoseFreshness(age: age),
                        bgColor: bgColor,
                        projectedColor: projectedColor,
                        recommendedBolus: model.recommendedBolus,
                        textFactor: textFactor,
                        isRefreshing: model.isRefreshing,
                        alert: model.snoozeStatus,
                        onRefresh: model.requestRefresh,
                        onSnooze: {
                            model.pendingSnoozeType = nil
                            model.showSnoozeSheet = true
                        },
                        onStop: {
                            WatchAlertManager.shared.stopAll()
                            model.refresh()
                        },
                        onCancelSnooze: {
                            WatchAlertManager.shared.cancelAllSnoozes()
                            model.refresh()
                        }
                    )
                    .equatable()
                }
            } else {
                // Nothing to count from yet; tapping still fetches.
                GlucosePlaceholder(caption: Button(action: model.requestRefresh) {
                    Label("No data", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .symbolEffect(.pulse, isActive: model.isRefreshing)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Refreshes"))
            }
        }
    }
}

/// How old the reading is. The sync counter is green, then yellow, then red, when the page
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
/// the reading, its freshness or its colors change. Sizes are the 46 mm layout's, scaled to this
/// screen; the rows' text also follows the watch's Text Size, and the BG number makes room.
private struct GlucoseReadingView: View, Equatable {
    let snapshot: GlucoseSnapshot
    let freshness: GlucoseFreshness
    let bgColor: Color
    let projectedColor: Color
    let recommendedBolus: Double?
    /// The watch's Text Size, as `WatchLayout.textFactor`.
    let textFactor: CGFloat
    let isRefreshing: Bool
    let alert: WatchAlertManager.SnoozeStatus
    /// Tapping the sync counter fetches the latest data, like pull-to-refresh on the phone.
    let onRefresh: () -> Void
    let onSnooze: () -> Void
    let onStop: () -> Void
    let onCancelSnooze: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.snapshot == b.snapshot && a.freshness == b.freshness && a.bgColor == b.bgColor
            && a.projectedColor == b.projectedColor && a.recommendedBolus == b.recommendedBolus
            && a.textFactor == b.textFactor && a.isRefreshing == b.isRefreshing && a.alert == b.alert
    }

    private var infoFontSize: CGFloat { WatchLayout.scaled(20) * textFactor }
    /// Delta and IOB stand out a little from the rest.
    private var emphasisFontSize: CGFloat { WatchLayout.scaled(22) * textFactor }
    /// The sync counter, battery and reservoir sit back a little from the rest.
    private var statusFontSize: CGFloat { WatchLayout.scaled(18) * textFactor }
    /// How far a row's text may shrink to fit its width rather than be cut off.
    private static let minimumScale: CGFloat = 0.6

    var body: some View {
        if freshness == .stale {
            // An alarm can still be sounding, or alerts snoozed, while the reading is too old to show.
            GlucosePlaceholder(caption: VStack(spacing: WatchLayout.scaled(4)) {
                refreshButton(syncCounter().lineLimit(1).minimumScaleFactor(Self.minimumScale))
                snoozeLine
            })
        } else {
            reading
        }
    }

    /// The BG number and trend, with a recommended bolus beside them. The number keeps its full
    /// size when there's room, and otherwise gives way, so a recommendation always shows; a wide
    /// one such as 14.5 ↑↑ comes down to about 80 %. Nothing is shown while the loop recommends none.
    private var glucoseRow: some View {
        ViewThatFits(in: .horizontal) {
            // Under half a hundredth would read as 0.00.
            if let rec = recommendedBolus, rec >= 0.005 {
                glucoseAndRecommendation(rec, scale: 1)
                glucoseAndRecommendation(rec, scale: 0.92)
                glucoseAndRecommendation(rec, scale: nil)
            } else {
                glucoseText(scale: 1)
            }
        }
    }

    private func glucoseText(scale: CGFloat) -> some View {
        Text("\(WatchFormat.glucose(snapshot)) \(WatchFormat.trendArrow(snapshot))")
            .font(.system(size: WatchLayout.scaled(56) * scale, weight: .bold, design: .rounded))
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .foregroundColor(bgColor)
    }

    /// At `scale`, or with no scale as small as the room beside the recommendation needs.
    private func glucoseAndRecommendation(_ rec: Double, scale: CGFloat?) -> some View {
        HStack(spacing: WatchLayout.scaled(4)) {
            if let scale {
                glucoseText(scale: scale)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                glucoseText(scale: 1)
            }
            Spacer(minLength: 0)
            RecommendedBolusBadge(units: rec, textFactor: textFactor)
        }
    }

    private func infoRow(_ text: Text, color: Color = .white) -> some View {
        text
            .font(.system(size: infoFontSize))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumScale)
    }

    /// Delta in larger text, then the projection when there is one.
    private var deltaAndProjection: some View {
        let s = snapshot
        return FittedRow(spacing: WatchLayout.scaled(12)) { fit in
            Text("Δ \(WatchFormat.delta(s))")
                .font(.system(size: emphasisFontSize * fit))
            if s.projected != nil {
                Text("Proj \(Text(WatchFormat.projected(s)).foregroundColor(projectedColor))")
                    .font(.system(size: infoFontSize * fit))
            }
        }
        .foregroundColor(.white)
    }

    /// IOB in larger yellow text and COB in purple, side by side; whichever is known. Units sit
    /// tight against the numbers so the pair fits the row.
    @ViewBuilder
    private var insulinAndCarbs: some View {
        let s = snapshot
        if s.iob != nil || s.cob != nil {
            FittedRow(spacing: WatchLayout.scaled(10)) { fit in
                if s.iob != nil {
                    Text("IOB \(WatchFormat.iob(s))U")
                        .font(.system(size: emphasisFontSize * fit))
                        .foregroundColor(.yellow)
                }
                if s.cob != nil {
                    Text("COB \(WatchFormat.cob(s))g")
                        .font(.system(size: infoFontSize * fit))
                        .foregroundColor(.purple)
                }
            }
        }
    }

    /// A sync icon and the time since the reading, counting up every second; it starts again from
    /// 0:00 when a new reading arrives, so a missed reading shows as 6:34, 6:35… The icon pulses
    /// while a refresh is under way.
    private func syncCounter(fit: CGFloat = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: statusFontSize * fit * 0.25) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.pulse, isActive: isRefreshing)
            Text(snapshot.updatedAt, style: .timer)
        }
        .font(.system(size: statusFontSize * fit))
        .monospacedDigit()
        .foregroundColor(freshness.color)
    }

    /// Makes `content` refresh when tapped. Only the sync counter does, so nothing else on the
    /// page fetches by mistake.
    private func refreshButton(_ content: some View) -> some View {
        Button(action: onRefresh) {
            content.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .accessibilityHint("Refreshes")
    }

    /// The sync counter, then the phone's battery when it's known, red under 20 % and with a bolt
    /// in place of the battery while charging, as on the phone; then the pump's reservoir.
    private var syncAndBattery: some View {
        let battery = snapshot.battery
        return FittedRow(spacing: WatchLayout.scaled(10)) { fit in
            refreshButton(syncCounter(fit: fit))
            if let battery {
                (batteryIcon(battery) + Text(" \(Int(battery.rounded()))%"))
                    .font(.system(size: statusFontSize * fit))
                    .monospacedDigit()
                    .foregroundColor(battery < 20 ? .red : .white)
            }
            if let reservoir = snapshot.pumpReservoirU {
                Text("\(Int(reservoir.rounded()))U")
                    .font(.system(size: statusFontSize * fit))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
        }
    }

    /// While an alarm sounds, buttons to snooze it, or to stop it and leave alerts on; while
    /// alerts are snoozed, until when, with a button to cancel. Nothing otherwise, and then the
    /// page is as usual; with it, the BG number makes room.
    @ViewBuilder
    private var snoozeLine: some View {
        switch alert {
        case .none:
            EmptyView()
        case .active:
            // Large and easy to hit during an alarm; the BG number and the rows make room for them.
            HStack(spacing: WatchLayout.scaled(6)) {
                Button(action: onSnooze) {
                    Label("Snooze…", systemImage: "bell.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WatchLayout.scaled(7))
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                Button(action: onStop) {
                    Text("Stop")
                        .padding(.horizontal, WatchLayout.scaled(12))
                        .padding(.vertical, WatchLayout.scaled(7))
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .foregroundColor(.white)
                .accessibilityHint("Stops the alarm; alerts stay on")
            }
            .buttonStyle(.plain)
            .font(.system(size: WatchLayout.scaled(19), weight: .bold))
            .foregroundColor(.orange)
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumScale)
            .padding(.top, WatchLayout.scaled(4))
        case let .snoozed(until):
            HStack(spacing: WatchLayout.scaled(6)) {
                Label {
                    Text("until \(until, style: .time)")
                } icon: {
                    Image(systemName: "bell.slash.fill")
                }
                .lineLimit(1)
                .minimumScaleFactor(Self.minimumScale)
                .accessibilityLabel("Alerts snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 0)
                Button("Cancel", action: onCancelSnooze)
                    .buttonStyle(.plain)
                    .padding(.horizontal, WatchLayout.scaled(10))
                    .padding(.vertical, WatchLayout.scaled(2))
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .accessibilityLabel("Cancel snooze")
            }
            .font(.system(size: statusFontSize * 0.9, weight: .semibold))
            .foregroundColor(.orange)
            .padding(.top, WatchLayout.scaled(2))
        }
    }

    /// A green bolt while charging, like the phone's ⚡️; otherwise a battery that empties with the level.
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

    private var reading: some View {
        let s = snapshot
        // Compact rows keep the BG number at full size on the fixed-height page.
        return VStack(alignment: .leading, spacing: WatchLayout.scaled(2)) {
            glucoseRow
                .frame(maxWidth: .infinity, alignment: .leading)
                // Digits and arrows sit well inside the font's line: drop the empty space above
                // them, and most of it below, to leave room for the rows.
                .padding(.top, -WatchLayout.scaled(12))
                .padding(.bottom, -WatchLayout.scaled(4))

            VStack(alignment: .leading, spacing: 0) {
                deltaAndProjection

                insulinAndCarbs

                // The basal is stale while the loop isn't running, so the warning takes its row and
                // the BG number keeps its size.
                if s.isNotLooping {
                    infoRow(Text("⚠ Loop inactive"), color: .yellow)
                } else if !s.basalRate.isEmpty {
                    infoRow(Text("Basal \(WatchFormat.basal(s)) U/h"), color: .blue)
                }

                syncAndBattery

                snoozeLine
            }
            // The rows get their full height first; when the page runs short, the BG number
            // gives way instead of the rows shrinking unevenly.
            .layoutPriority(1)
        }
        .padding(.horizontal, GlucoseView.sideMargin)
    }
}

/// The loop's recommended bolus, in blue. It only shows while one is recommended, so its
/// appearing is the signal; it holds still rather than blink like an alarm.
private struct RecommendedBolusBadge: View {
    let units: Double
    let textFactor: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("Rec")
                .font(.system(size: WatchLayout.scaled(12) * textFactor))
            Text("\(String(format: "%.2f", units))U")
                .font(.system(size: WatchLayout.scaled(16) * textFactor, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundColor(.blue)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recommended bolus \(String(format: "%.2f", units)) units")
    }
}

/// Texts side by side on one line that shrink together when they don't fit at full size, so
/// neither gets cut off; `content` builds them at a share of their full size.
private struct FittedRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(fit: 1).fixedSize()
            row(fit: 0.9).fixedSize()
            row(fit: 0.8).fixedSize()
            row(fit: 0.7).fixedSize()
            // Very long values: smaller still, cut off only past that.
            row(fit: 0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func row(fit: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing * fit) {
            content(fit)
        }
    }
}

/// "--" with a caption under it, in the middle of the page.
private struct GlucosePlaceholder<Caption: View>: View {
    let caption: Caption

    var body: some View {
        VStack(spacing: WatchLayout.scaled(4)) {
            Text("--")
                .font(.system(size: WatchLayout.scaled(44), weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            caption
        }
        .padding(.horizontal, GlucoseView.sideMargin)
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
