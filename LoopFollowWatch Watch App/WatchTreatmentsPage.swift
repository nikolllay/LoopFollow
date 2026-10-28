// LoopFollow
// WatchTreatmentsPage.swift

import Combine
import SwiftUI

/// Loads treatments from Nightscout for the Treatments page, a page at a time, the way the
/// phone's Treatments screen does.
@MainActor
final class WatchTreatmentsLoader: ObservableObject {
    @Published private(set) var entries: [WatchTreatmentEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// Whether Nightscout may have older treatments than those loaded.
    @Published private(set) var hasMore = false

    private var seenIDs = Set<String>()
    /// The oldest treatment time asked for so far; the next page ends there.
    private var oldestRequested: Date?
    private var lastLoaded: Date?

    /// Loads the newest page, unless it was loaded in the last minute.
    func refreshIfStale(unit: GlucoseSnapshot.Unit) {
        if let lastLoaded, Date().timeIntervalSince(lastLoaded) < 60 { return }
        Task { await refresh(unit: unit) }
    }

    func refresh(unit: GlucoseSnapshot.Unit) async {
        guard !isLoading else { return }
        guard let (page, isFull) = await load(before: Date(), unit: unit, seen: []) else { return }
        seenIDs = page.ids
        entries = page.entries
        oldestRequested = page.oldest
        hasMore = isFull
        lastLoaded = Date()
    }

    func loadMore(unit: GlucoseSnapshot.Unit) async {
        guard !isLoading, hasMore, let before = oldestRequested else { return }
        guard let (page, isFull) = await load(before: before, unit: unit, seen: seenIDs) else { return }
        seenIDs.formUnion(page.ids)
        entries += page.entries
        oldestRequested = page.oldest ?? before
        hasMore = isFull
    }

    /// A page of treatments before `end`, and whether it was full, which means there may be more.
    private func load(before end: Date, unit: GlucoseSnapshot.Unit, seen: Set<String>) async -> (WatchTreatmentList.Page, Bool)? {
        let base = LAAppGroupSettings.watchNightscoutURL()
        guard !base.isEmpty else {
            error = "Set up Nightscout on the phone to see treatments here."
            return nil
        }
        // Only over https, so the token never travels in the clear.
        guard let url = Self.url(base: base, before: end) else {
            error = "The Watch reaches Nightscout only over https."
            return nil
        }
        isLoading = true
        defer { isLoading = false }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                error = status == 401 ? "Nightscout refused the token." : "Nightscout answered \(status)."
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                error = "Nightscout's answer couldn't be read."
                return nil
            }
            error = nil
            return (WatchTreatmentList.page(from: json, unit: unit, skipping: seen), json.count >= WatchTreatmentList.pageSize)
        } catch {
            self.error = "Can't reach Nightscout."
            return nil
        }
    }

    /// The phone's query: up to a page of treatments before `end`, within a year of it. Nil
    /// unless `base` is an https address.
    private static func url(base: String, before end: Date) -> URL? {
        guard base.lowercased().hasPrefix("https://"), var components = URLComponents(string: base) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Calendar.current.date(byAdding: .day, value: -365, to: end) ?? end
        components.path = "/api/v1/treatments.json"
        var items = [
            URLQueryItem(name: "find[created_at][$gte]", value: formatter.string(from: start)),
            URLQueryItem(name: "find[created_at][$lt]", value: formatter.string(from: end)),
            URLQueryItem(name: "count", value: "\(WatchTreatmentList.pageSize)"),
        ]
        let token = LAAppGroupSettings.watchNightscoutToken()
        if !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items
        return components.url
    }
}

/// The treatments from Nightscout, newest first and grouped by day, like the phone's
/// Treatments screen. They load when the page is shown.
struct WatchTreatmentsPage: View {
    let unit: GlucoseSnapshot.Unit
    /// Whether this is the page on screen; it loads only then.
    let isVisible: Bool

    @StateObject private var loader = WatchTreatmentsLoader()
    /// SMB and automatic boluses to start with: the loop's own dosing is what's most often checked.
    @State private var filter = Filter.automatic

    /// In the order the "Show" picker lists them.
    enum Filter: CaseIterable {
        case automatic
        case all
        case carbs
        case bolus
        case basal

        var title: String {
            switch self {
            case .all: "All"
            case .carbs: "Carbs"
            case .bolus: "Boluses"
            case .automatic: "SMB / Automatic"
            case .basal: "Temp Basals"
            }
        }

        func includes(_ kind: WatchTreatmentEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .carbs: kind == .carbs
            case .bolus: kind == .bolus
            case .automatic: kind == .smb || kind == .automaticBolus
            case .basal: kind == .tempBasal
            }
        }
    }

    private var shown: [WatchTreatmentEntry] {
        loader.entries.filter { filter.includes($0.kind) }
    }

    /// Days, newest first, with their treatments.
    private var days: [(day: Date, entries: [WatchTreatmentEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: shown) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.date)) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        // The filter picker opens its choices as a pushed screen, which needs a navigation stack.
        NavigationStack {
            list
                .navigationTitle("Treatments")
        }
    }

    private var list: some View {
        List {
            filterPicker

            if loader.entries.isEmpty, loader.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if loader.entries.isEmpty, let error = loader.error {
                VStack(spacing: 6) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await loader.refresh(unit: unit) } }
                }
                .frame(maxWidth: .infinity)
            } else if shown.isEmpty, !loader.isLoading {
                Text("No recent treatments")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(days, id: \.day) { day in
                Section(Self.dayTitle(day.day)) {
                    ForEach(day.entries) { entry in
                        TreatmentRow(entry: entry)
                    }
                }
            }

            // A refresh or a further page that failed leaves the list as it was; say so.
            if !loader.entries.isEmpty, let error = loader.error {
                Text("Couldn't update: \(error)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if loader.hasMore, !loader.entries.isEmpty {
                Button {
                    Task { await loader.loadMore(unit: unit) }
                } label: {
                    if loader.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Load More").frame(maxWidth: .infinity)
                    }
                }
                .disabled(loader.isLoading)
            }
        }
        .refreshable { await loader.refresh(unit: unit) }
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible { loader.refreshIfStale(unit: unit) }
        }
    }

    /// Which treatments to show, as the phone's filters choose them.
    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(Filter.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// One treatment: its symbol and color as on the phone, the amount, and what and when.
private struct TreatmentRow: View {
    let entry: WatchTreatmentEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .opacity(entry.kind == .tempBasal ? 0.5 : 1)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(entry.subtitle) · \(Date(timeIntervalSince1970: entry.date).formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch entry.kind {
        case .carbs, .bolus: "circle.fill"
        case .automaticBolus, .smb: "arrowtriangle.down.fill"
        case .tempBasal: "chart.xyaxis.line"
        case .override: "slider.horizontal.3"
        case .tempTarget: "scope"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .carbs: .orange
        case .bolus, .automaticBolus, .smb, .tempBasal: .blue
        case .override: .purple
        case .tempTarget: .green
        }
    }
}
