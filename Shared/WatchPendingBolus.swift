// LoopFollow
// WatchPendingBolus.swift

import Foundation

/// A bolus sent from the Watch that the loop may not have accounted for yet.
///
/// The recommended bolus shown on the Watch comes from the last loop run. Until the
/// loop runs again after a Watch bolus, that recommendation still assumes the insulin
/// was not given, so the Watch subtracts it to avoid prompting a second dose.
struct WatchPendingBolus: Codable, Equatable {
    let units: Double
    let sentAt: Date

    /// The loop must have run at least this long after the bolus to have seen it.
    static let loopPickupDelay: TimeInterval = 60
    /// After this long the adjustment is dropped whatever the loop has reported.
    static let maximumAge: TimeInterval = 15 * 60

    /// Whether this bolus is still missing from a recommendation computed at `loopRanAt`.
    func isPending(loopRanAt: Date?, now: Date) -> Bool {
        guard now.timeIntervalSince(sentAt) < Self.maximumAge else { return false }
        guard let loopRanAt else { return true }
        return loopRanAt < sentAt.addingTimeInterval(Self.loopPickupDelay)
    }

    /// The recommendation to display: less every Watch bolus the loop hasn't seen yet, never below zero.
    static func adjustedRecommendation(_ recommended: Double, pending: [WatchPendingBolus], loopRanAt: Date?, now: Date) -> Double {
        let unseen = pending.filter { $0.isPending(loopRanAt: loopRanAt, now: now) }.reduce(0) { $0 + $1.units }
        return max(0, recommended - unseen)
    }

    /// The recommendation to display when at most one Watch bolus is known.
    static func adjustedRecommendation(_ recommended: Double, pending: WatchPendingBolus?, loopRanAt: Date?, now: Date) -> Double {
        adjustedRecommendation(recommended, pending: pending.map { [$0] } ?? [], loopRanAt: loopRanAt, now: now)
    }

    // MARK: - Persistence (Watch App Group)

    /// Every Watch bolus still young enough to matter. Two boluses sent before the loop runs
    /// must both be subtracted, so this is a list rather than a single slot.
    private static let key = "watch.pendingBoluses"
    /// Where earlier builds kept their single pending bolus.
    private static let singleBolusKey = "watch.pendingBolus"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.current())
    }

    /// Pending boluses younger than `maximumAge`.
    static func loadAll(now: Date = Date()) -> [WatchPendingBolus] {
        let decoder = JSONDecoder()
        var all: [WatchPendingBolus] = []
        if let data = defaults?.data(forKey: key), let list = try? decoder.decode([WatchPendingBolus].self, from: data) {
            all = list
        }
        if let data = defaults?.data(forKey: singleBolusKey), let single = try? decoder.decode(WatchPendingBolus.self, from: data) {
            all.append(single)
        }
        return all.filter { now.timeIntervalSince($0.sentAt) < maximumAge }
    }

    /// Adds this bolus to the pending ones.
    func record(now: Date = Date()) {
        Self.store(Self.loadAll(now: now) + [self])
    }

    /// Adds this bolus unless one of the same amount is already pending: for a resend the phone
    /// refused because the first one may have gone out, which was recorded when it was sent.
    func recordUnlessPending(now: Date = Date()) {
        let all = Self.loadAll(now: now)
        guard !all.contains(where: { abs($0.units - units) < 1e-6 }) else { return }
        Self.store(all + [self])
    }

    private static func store(_ list: [WatchPendingBolus]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults?.set(data, forKey: key)
        defaults?.removeObject(forKey: singleBolusKey)
    }
}
