import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Nightly irregular-rhythm share (Explore / Compare metric)
//
// One number per night, stored like the other computed daily series under the "-noop" source so it shows in
// Explore and Compare: the share of the night's analysed beats that formed an irregular rhythm
// (`StrandAnalytics.IrregularRhythm`, burden %). A night with too few clean beats (under an hour analysed) has
// NO value, never a zero: "regular" and "could not tell" are different statements.
//
// Cost: the last two nights are re-screened on every pass (the newest one grows while the strap syncs); an older
// night is screened only when it has no stored value and has not already been tried in this app run, so a night
// the strap never recorded is not re-read every ten minutes. Screening a night reads its beats from the store
// and runs the engine off the main actor (`Repository.irregularRhythm(for:)`).
//
// Informational only. NOOP is not a medical device; this is a screen for a pattern like atrial fibrillation,
// not a diagnosis.

extension IntelligenceEngine {

    /// Metric key (under the "-noop" source) of the nightly irregular-rhythm share, in percent.
    static let irregularRhythmKey = "irregular_rhythm_pct"

    /// Screen the nights that need it and store, replace or drop their points. Called at the end of a scoring pass.
    func updateIrregularRhythmSeries(store: WhoopStore, repository: Repository, computedId: String) async {
        let key = Self.irregularRhythmKey
        let nights = repository.mainSleeps()
        guard let firstNight = nights.first, let lastNight = nights.last else { return }

        let stored = (try? await store.metricSeries(deviceId: computedId, key: key,
                                                    from: firstNight.day, to: lastNight.day)) ?? []
        let storedByDay = Dictionary(stored.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })

        var upserts: [MetricPoint] = []
        var evictions: [String] = []
        for (index, night) in nights.enumerated() {
            let isRecent = index >= nights.count - 2
            let tryKey = "\(night.day)|\(night.start)|\(night.end)"
            if !isRecent {
                if storedByDay[night.day] != nil || irregularRhythmTried.contains(tryKey) { continue }
            }
            irregularRhythmTried.insert(tryKey)
            let result = await repository.irregularRhythm(for: night)
            if result.verdict == .notEnoughData {
                if storedByDay[night.day] != nil { evictions.append(night.day) }
                continue
            }
            let value = (result.burdenPercent * 10).rounded() / 10
            if let old = storedByDay[night.day], abs(old - value) < 1e-9 { continue }
            upserts.append(MetricPoint(day: night.day, key: key, value: value))
        }

        if !upserts.isEmpty {
            _ = try? await store.upsertMetricSeries(upserts, deviceId: computedId)
        }
        for day in evictions {
            _ = try? await store.deleteMetricSeries(deviceId: computedId, key: key, from: day, to: day)
        }
    }
}

/// Nights (day|start|end) already screened in this app run, so an old night that yielded no value is not read
/// again on every pass. Cleared when the app restarts; a new window for the same day (an edited night) differs.
@MainActor private var irregularRhythmTried = Set<String>()
