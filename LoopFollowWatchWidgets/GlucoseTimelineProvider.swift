// LoopFollow
// GlucoseTimelineProvider.swift

import WidgetKit

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseSnapshot?
    let history: [WatchGlucoseHistory.Point]

    /// Readings older than this render as stale ("--").
    static let staleAfter: TimeInterval = 15 * 60

    /// Age of the reading at the time this entry is displayed.
    var readingAge: TimeInterval? {
        snapshot.map { date.timeIntervalSince($0.updatedAt) }
    }

    var isStale: Bool {
        guard let readingAge else { return true }
        return readingAge >= Self.staleAfter || snapshot?.isNotLooping == true
    }

    static let placeholder = GlucoseEntry(
        date: Date(),
        snapshot: GlucoseSnapshot(
            glucose: 112,
            delta: 2,
            trend: .flat,
            updatedAt: Date(),
            iob: nil,
            cob: nil,
            projected: nil,
            unit: .mgdl,
            isNotLooping: false
        ),
        history: []
    )
}

/// Reads the snapshot and history the Watch app persisted in the App Group. The Watch
/// app reloads this timeline whenever new data arrives, so the provider never fetches.
struct GlucoseTimelineProvider: TimelineProvider {
    /// How far ahead a timeline reaches; new data reloads it well before that.
    private static let span: TimeInterval = 60 * 60

    func placeholder(in _: Context) -> GlucoseEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        completion(context.isPreview ? .placeholder : entry(at: Date()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        let now = Date()
        let snapshot = GlucoseSnapshotStore.shared.load()
        let history = WatchGlucoseHistory.load()?.points ?? []
        let entries = Self.entryDates(from: now, readingAt: snapshot?.updatedAt).map {
            GlucoseEntry(date: $0, snapshot: snapshot, history: history)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.span))))
    }

    /// An entry a minute while the reading is fresh, so its age label and the switch to stale
    /// advance without reloads, then one every 5 minutes for the age of a stale "--". Every
    /// entry is drawn ahead of time on each reload, so fewer of them cost less.
    private static func entryDates(from now: Date, readingAt: Date?) -> [Date] {
        let staleAt = readingAt.map { $0.addingTimeInterval(GlucoseEntry.staleAfter) } ?? now
        let end = now.addingTimeInterval(span)
        var dates: [Date] = []
        var date = now
        while date < end {
            dates.append(date)
            date = date.addingTimeInterval(date < staleAt ? 60 : 5 * 60)
        }
        return dates
    }

    private func entry(at date: Date) -> GlucoseEntry {
        GlucoseEntry(
            date: date,
            snapshot: GlucoseSnapshotStore.shared.load(),
            history: WatchGlucoseHistory.load()?.points ?? []
        )
    }
}
