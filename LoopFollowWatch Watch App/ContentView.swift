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
                    VStack(spacing: WatchLayout.scaled(12)) {
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
        // On the glucose page, the pump and sensor ages sit left of the clock, centered in its
        // row: space the page doesn't otherwise use, whose height differs between watch sizes.
        .overlay(alignment: .topLeading) {
            if page == 0 {
                GeometryReader { geo in
                    DeviceAgeBadges(
                        pumpChangedAt: model.snapshot?.cageInsertTime ?? 0,
                        sensorChangedAt: model.snapshot?.sageInsertTime ?? 0,
                        pumpColoring: model.pumpAgeColoring,
                        sensorColoring: model.sensorAgeColoring
                    )
                    // Clear of the clock, which takes a little over the right third of the row.
                    .frame(maxWidth: geo.size.width * 0.6, alignment: .leading)
                    .frame(height: geo.safeAreaInsets.top)
                    .padding(.leading, WatchLayout.scaled(16))
                    .offset(y: -geo.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
        }
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
    /// The phone's CAGE and SAGE coloring, for the pump and sensor ages.
    @Published var pumpAgeColoring = LAAppGroupSettings.watchPumpAgeColoring()
    @Published var sensorAgeColoring = LAAppGroupSettings.watchSensorAgeColoring()

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
        setIfChanged(\.selectedSlots, LAAppGroupSettings.watchSelectedSlots())
        setIfChanged(\.isSnoozed, WatchAlertManager.shared.isGloballySnoozed)
        setIfChanged(\.snoozeUntil, WatchAlertManager.shared.globalSnoozeExpiryDate)
        setIfChanged(\.hasActiveAlert, snapshot.map { WatchAlertManager.shared.hasActiveAlert(for: $0) } ?? false)
        setIfChanged(\.remoteEnabled, LAAppGroupSettings.isWatchRemoteEnabled())
        setIfChanged(\.bgColors, GlucoseColor.Scheme.current())
        setIfChanged(\.pumpAgeColoring, LAAppGroupSettings.watchPumpAgeColoring())
        setIfChanged(\.sensorAgeColoring, LAAppGroupSettings.watchSensorAgeColoring())
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
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The settings, remote and refresh icons in the top-right column.
    static let iconSize = WatchLayout.scaled(18)
    static let iconFrame = WatchLayout.scaled(34)

    var body: some View {
        Group {
            if let s = model.snapshot {
                let bgColor = model.bgColors.color(forMgdl: s.glucose)
                let textFactor = WatchLayout.textFactor(for: typeSize)
                // Ticks every second so the counter's color, and the switch to "--" once the
                // reading is too old, land on time. A tick only works out the freshness; the page
                // redraws when that, the reading or its color changes. An explicit schedule for
                // just those moments didn't fire reliably on watchOS.
                TimelineView(.periodic(from: s.updatedAt, by: 1)) { context in
                    let age = max(context.date, Date()).timeIntervalSince(s.updatedAt)
                    GlucoseReadingView(snapshot: s, freshness: GlucoseFreshness(age: age), bgColor: bgColor, textFactor: textFactor)
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
/// the reading, its freshness or its color changes. Sizes are the 46 mm layout's, scaled to this
/// screen; the rows' text also follows the watch's Text Size, and the BG number makes room.
private struct GlucoseReadingView: View, Equatable {
    let snapshot: GlucoseSnapshot
    let freshness: GlucoseFreshness
    let bgColor: Color
    /// The watch's Text Size, as `WatchLayout.textFactor`.
    let textFactor: CGFloat

    private var infoFontSize: CGFloat { WatchLayout.scaled(20) * textFactor }
    /// Delta and IOB stand out a little from the rest.
    private var emphasisFontSize: CGFloat { WatchLayout.scaled(24) * textFactor }
    /// How far a row's text may shrink to fit its width rather than be cut off.
    private static let minimumScale: CGFloat = 0.6

    var body: some View {
        if freshness == .stale {
            GlucosePlaceholder(caption: syncCounter().lineLimit(1).minimumScaleFactor(Self.minimumScale))
        } else {
            reading
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
                Text("Proj \(WatchFormat.projected(s))")
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
    /// 0:00 when a new reading arrives, so a missed reading shows as 6:34, 6:35…
    private func syncCounter(fit: CGFloat = 1) -> Text {
        (Text(Image(systemName: "arrow.triangle.2.circlepath")) + Text(" ") + Text(snapshot.updatedAt, style: .timer))
            .font(.system(size: infoFontSize * fit))
            .monospacedDigit()
            .foregroundColor(freshness.color)
    }

    /// The sync counter, then the phone's battery when it's known: red under 20 %.
    private var syncAndBattery: some View {
        let battery = snapshot.battery
        return FittedRow(spacing: WatchLayout.scaled(10)) { fit in
            syncCounter(fit: fit)
            if let battery {
                (Text(Image(systemName: Self.batterySymbol(battery))) + Text(" \(Int(battery.rounded()))%"))
                    .font(.system(size: infoFontSize * fit))
                    .monospacedDigit()
                    .foregroundColor(battery < 20 ? .red : .white)
            }
        }
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
            Text("\(WatchFormat.glucose(s)) \(WatchFormat.trendArrow(s))")
                .font(.system(size: WatchLayout.scaled(56), weight: .bold, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundColor(bgColor)
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
            }
            // The rows get their full height first; when the page runs short, the BG number
            // gives way instead of the rows shrinking unevenly.
            .layoutPriority(1)
        }
        .padding(.leading, WatchLayout.scaled(4))
        // Keep clear of the icon column on the right.
        .padding(.trailing, GlucoseView.iconFrame)
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
