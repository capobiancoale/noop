#if os(iOS)
import Foundation
import HealthKit
import UIKit
import WhoopStore
import StrandImport

/// Two-way Apple Health bridge for the iOS app.
///
/// iOS has HealthKit (macOS does not), so the iOS target can do far more than parse a static export:
/// it reads the user's own Health data live and maps it onto the **same** `WhoopStore` rows the
/// macOS importer produces (under the `apple-health` source id), and it writes NOOP-computed metrics
/// back into Apple Health. Everything stays on-device and strictly opt-in.
@MainActor
final class HealthKitBridge: ObservableObject {

    enum AuthState: Equatable {
        case unknown, unavailable, denied, authorized
        /// The build can't talk to HealthKit at all: it was re-signed (free Apple ID / AltStore /
        /// Sideloadly) WITHOUT the `com.apple.developer.healthkit` entitlement, so the framework is
        /// present but the app can never read/write Health and can never appear under
        /// Settings › Health › Data Access & Devices. Distinct from `.denied` (entitled build, user
        /// said no) and `.unavailable` (no HealthKit hardware) so the UI can route to the honest
        /// file/Shortcuts import path instead of giving impossible Settings instructions (#348).
        case entitlementMissing
    }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// The most recent failure surfaced by `sync` / `writeBack`. Cleared on a successful run. UI binds
    /// here so an Apple Health auth revoke, quota hit, or invalid sample is visible instead of silent.
    @Published private(set) var lastError: String?
    /// What the running import is doing, for the progress bars (nil when nothing is running).
    @Published private(set) var progress: SyncProgress?
    /// A calm status line, not an error: why an import paused, and that it carries on by itself.
    @Published private(set) var statusNote: String?

    /// Progress of one sync run.
    struct SyncProgress: Equatable {
        /// 0…1 over the whole run.
        var fraction: Double
        /// What is being read now ("Heart", "Sleep", "Saving…"), localized.
        var step: String
        /// The days of the window being read, e.g. "27 Jul – 25 Aug 2026", localized.
        var period: String
        /// Part of the one-time history import (about 14 months), not only a refresh of recent days.
        var isHistoryImport: Bool
        /// Started from a button (Enable / Sync now / Resume) rather than by the app on its own.
        var userInitiated: Bool
        /// The floating banner shows the long or asked-for runs; a quiet refresh shows only in Apple Health.
        var showsBanner: Bool { isHistoryImport || userInitiated }
    }

    private let store = HKHealthStore()
    private let repo: Repository
    /// Source id imported HealthKit data lands under (matches `AppModel.appleDeviceId`).
    private let appleDeviceId: String
    /// NOOP's own strap-derived source id, read back when writing into Health.
    private let noopDeviceId: String
    /// NOOP's on-device COMPUTED daily scores (recovery/HRV/RHR/SpO₂/resp) live under the sibling
    /// `deviceId + "-noop"` id — mirrors `Repository.computedDeviceId` / `IntelligenceEngine.computedId`.
    /// `writeBack` must read this, not the raw import id: a Bluetooth-only WHOOP user has no imported
    /// `noopDeviceId` daily row, so those metrics exist ONLY here.
    private var computedDeviceId: String { noopDeviceId + "-noop" }

    init(repo: Repository, appleDeviceId: String, noopDeviceId: String) {
        self.repo = repo
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId
        // Order matters: a free-signed build with no HealthKit entitlement is dead in the water even
        // where the hardware supports Health, so surface that first. `.unavailable` (no HealthKit at
        // all, e.g. iPad without the framework) still wins where it applies because we only reach the
        // entitlement check when `isHealthDataAvailable()` is true.
        if !HKHealthStore.isHealthDataAvailable() {
            auth = .unavailable
        } else if !HealthKitBridge.hasHealthKitEntitlement {
            auth = .entitlementMissing
        }
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for id in HealthKitBridge.quantityReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s
    }

    // Every id here ends up in the HealthKit permission dialog. Only request what `sync` actually
    // aggregates into `HealthImportReader.DayAgg`; adding read scopes the app never consumes makes the consent prompt
    // noisier and surfaces a privacy ask we don't honour.
    private static let quantityReadIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max,
        // Body composition — READ-ONLY (#20). Imported under the apple-health source like the file
        // importer already ingests; deliberately NOT in quantityWriteIds (we never write these back).
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex,
        // Diabetes data — READ-ONLY. An automated-insulin-delivery app (e.g. Loop) writes these into
        // Apple Health; NOOP surfaces them as daily aggregates (mean/min/max glucose, total daily
        // insulin, carbs) purely for informational trends. NEVER in quantityWriteIds: NOOP must never
        // author glucose/insulin/carb samples, and this display is not for treatment decisions.
        .bloodGlucose, .insulinDelivery, .dietaryCarbohydrates,
        // Body / vitals extras useful to a diabetic athlete — READ-ONLY. Blood pressure, hydration
        // and waist circumference; never written back.
        .bloodPressureSystolic, .bloodPressureDiastolic, .dietaryWater, .waistCircumference
    ]
    private static let quantityWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate
    ]

    // MARK: - Authorization

    /// Request read + write permission. HealthKit never reveals whether *read* was granted, so we
    /// treat a successful request as `.authorized` and let queries return empty if the user declined.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        // A free-signed build (no `com.apple.developer.healthkit` entitlement) can NEVER reach Health:
        // `requestAuthorization` either throws "Missing application-identifier"/"missing entitlement"
        // or returns without ever presenting the sheet and leaves every type `.notDetermined`. Either
        // way the honest answer is "this build can't use Apple Health directly", NOT "you denied it" —
        // so never fall through to `.denied` (which tells the user to fix it in Settings, where the app
        // can never appear). Detect via the embedded provisioning profile up front (#348).
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            // The entitlement is present (the guard above proved it via the embedded profile, or there's
            // no profile = App Store build), so a successful request means the bridge is usable. We do
            // NOT reclassify to `.entitlementMissing` off the post-request `.notDetermined` heuristic
            // here: on a genuinely-entitled build the user could grant only reads (writes stay
            // `.notDetermined`) or dismiss the share sheet, and that must stay `.authorized` with the
            // normal Settings guidance — never the file-import reroute. The provisioning-profile check is
            // the authoritative signal; the `.notDetermined` fallback only matters when that check can't
            // run, which on iOS means an App Store build that by definition has the entitlement.
            auth = .authorized
        } catch {
            // A thrown error here is on a build that carries the entitlement (guarded above), so it's a
            // genuine denial / request failure — keep the normal `.denied` "enable in Settings" path,
            // never the entitlement-missing reroute.
            auth = .denied
        }
        // First successful grant in this process: arm the live HealthKit stream so a watch-only user
        // gets continuous ingestion (new SDNN/RHR/sleep/etc. land within the hour) instead of only on
        // app foreground. Guarded inside enableLiveDelivery on auth == .authorized, so the .denied path
        // above is a no-op.
        enableLiveDelivery()
    }

    /// Resume a prior grant on launch without re-prompting. `auth` is a fresh `.unknown` every
    /// process (the bridge isn't persisted), so a user who already enabled Apple Health would
    /// otherwise have to re-tap "Enable" each session before the scenePhase sync runs. HealthKit
    /// never reveals *read* status, but *write*/share status is observable — if the user already
    /// authorized all of our write types, treat the bridge as `.authorized`. This only reads
    /// status, so no system permission sheet is shown.
    func refreshAuthIfPreviouslyGranted() {
        guard auth == .unknown, HKHealthStore.isHealthDataAvailable() else { return }
        let granted = writeTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
        if granted {
            auth = .authorized
            // A returning user who already granted access should get the live stream re-armed for this
            // process. enableLiveDelivery is idempotent (HealthKit dedups observers + background
            // delivery per type), so calling it here as well as after a fresh requestAuthorization is safe.
            enableLiveDelivery()
        }
    }

    // MARK: - Live delivery (continuous ingestion)

    /// The scored read types we want a live observer + hourly background delivery on. This is the
    /// subset of `quantityReadIds` (plus sleep) that actually feeds Charge/Rest/Effort/Fitness Age, so
    /// a watch-only user's numbers refresh on their own rather than only when the app is foregrounded.
    /// We deliberately do NOT observe the body-composition reads (weight/BMI/etc.) — those don't move a
    /// score and a manual weigh-in shouldn't wake the app every hour.
    private static let liveQuantityIds: [HKQuantityTypeIdentifier] = [
        .heartRateVariabilitySDNN, .restingHeartRate, .activeEnergyBurned, .heartRate, .vo2Max
    ]

    /// Long-lived observer queries, retained so HealthKit doesn't tear them down. Keyed by the sample
    /// type's identifier so a second `enableLiveDelivery()` call replaces rather than duplicates.
    private var observerQueries: [String: HKObserverQuery] = [:]

    /// Register one `HKObserverQuery` per scored read type and turn on hourly background delivery, so
    /// new Apple Watch data is ingested continuously. Each observer's update handler runs an anchored
    /// delta sync of just the affected window and then calls HealthKit's completion handler (required —
    /// HealthKit stops delivering to an observer that never acknowledges). Idempotent and guarded behind
    /// `auth == .authorized`; safe to call from several entry points.
    func enableLiveDelivery() {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }

        var types: [HKSampleType] = []
        for id in HealthKitBridge.liveQuantityIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.append(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }

        for type in types {
            let key = type.identifier
            // Tear down a prior observer for this type before re-registering, so a re-arm (e.g. a
            // returning user hitting both requestAuthorization and refreshAuthIfPreviouslyGranted) can
            // never leave two live observers fighting over the same completion handler.
            if let existing = observerQueries[key] {
                store.stop(existing)
                observerQueries[key] = nil
            }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                // HealthKit invokes this on a background queue. Hop to the main actor (the bridge is
                // @MainActor and `sync` mutates published state), run the incremental catch-up, then
                // ALWAYS call completion so HealthKit keeps delivering. We don't tie completion to sync
                // success: a transient store error shouldn't make HealthKit think we never handled the
                // update and back off — the next foreground catch-up will reconcile.
                guard let self else { completion(); return }
                Task { @MainActor in
                    await self.syncFromObserver(type: type)
                    completion()
                }
            }
            store.execute(observer)
            observerQueries[key] = observer

            // Hourly is the finest cadence HealthKit honours for most types and is plenty for daily
            // aggregate scores. Failure here is non-fatal: the foreground catch-up still backfills.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Foreground catch-up. Call on app-active so anything background delivery missed (the system can
    /// throttle or skip wakes) is backfilled. A short window is enough because live delivery keeps the
    /// recent days current; 7 covers a weekend of missed wakes. Exposed for the existing scenePhase
    /// hook in `StrandiOSApp` to call — no other file is edited.
    func foregroundCatchUp() async {
        await sync(days: HealthImportPlan.catchUpDays)
    }

    /// Drive an incremental sync off an observer wake. We use an `HKAnchoredObjectQuery` per type to
    /// learn the span of days touched since we last looked (persisting the anchor so the same samples
    /// aren't walked twice and nothing between wakes is missed), then re-aggregate just that day window
    /// via the existing `sync(days:)` path. Re-aggregating the window (rather than the deltas alone)
    /// keeps every per-day average correct and idempotent — `sync` upserts are keyed by day.
    private func syncFromObserver(type: HKSampleType) async {
        guard auth == .authorized else { return }
        let touched = await fetchTouchedDayWindow(type: type)
        // No new samples since the last anchor (a spurious wake): nothing to do.
        guard let touched else { return }
        let cal = Calendar.current
        let daysBack = cal.dateComponents([.day], from: cal.startOfDay(for: touched),
                                          to: cal.startOfDay(for: Date())).day ?? 0
        // Clamp to a sane window: at least today, and never re-walk more than a month from one wake. An
        // observer wake (often in the background, often locked) never takes on the history import.
        let window = max(1, min(31, daysBack + 1))
        await sync(days: window, includeHistory: false)
    }

    /// Advance this type's stored anchor over any new samples and return the OLDEST sample date seen,
    /// or nil when there were no new samples. Anchors are persisted in UserDefaults per type so live
    /// deltas are neither re-ingested nor missed across launches. We don't consume the samples here —
    /// `sync(days:)` re-reads the aggregate for the affected window — the anchor's only job is to tell
    /// us how far back the change reached.
    private func fetchTouchedDayWindow(type: HKSampleType) async -> Date? {
        let key = HealthKitBridge.anchorDefaultsKey(for: type)
        let priorAnchor: HKQueryAnchor? = {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }()

        return await withCheckedContinuation { (cont: CheckedContinuation<Date?, Never>) in
            let q = HKAnchoredObjectQuery(
                type: type, predicate: Self.notNoopAuthored,
                anchor: priorAnchor, limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, _ in
                // Persist the advanced anchor so the next wake only sees genuinely-new samples. Skip the
                // write on a query error (newAnchor nil) so we don't blow away a good cursor.
                if let newAnchor,
                   let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: key)
                }
                let oldest = (samples ?? []).map { $0.startDate }.min()
                cont.resume(returning: oldest)
            }
            store.execute(q)
        }
    }

    /// UserDefaults key for a type's persisted HealthKit anchor. Namespaced so it can't collide with
    /// other app defaults, and keyed by the stable HK identifier so it survives across launches.
    private static func anchorDefaultsKey(for type: HKSampleType) -> String {
        "hkAnchor.v1.\(type.identifier)"
    }

    // MARK: - Read → store

    /// Pause / resume and background-time state of the running import.
    private var pauseRequested = false
    private var resyncRequested = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let historyDoneKey = "hkHistoryImport.v2.done"
    private static let historySavedFromKey = "hkHistoryImport.v2.savedFrom"
    private static let lastFullRefreshKey = "hkRecentRefresh.v1.at"

    /// Start of the oldest history window already saved (nil when the history import hasn't saved any).
    private var historySavedFrom: Date? {
        let t = UserDefaults.standard.double(forKey: Self.historySavedFromKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// When the last `HealthImportPlan.recentDays` refresh finished (persisted across launches).
    private var lastFullRefresh: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.lastFullRefreshKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastFullRefreshKey) }
    }

    /// Share (0…1) of the one-time history import saved so far; 1 once complete.
    var historyFraction: Double {
        if UserDefaults.standard.bool(forKey: Self.historyDoneKey) { return 1 }
        return HealthImportPlan.historyFraction(savedFrom: historySavedFrom, now: Date())
    }

    /// Ask the running import to stop after the reads in flight. Everything already saved stays saved; the
    /// next sync (the next time NOOP opens, or Resume) carries on from there.
    func pauseSync() {
        guard syncing else { return }
        pauseRequested = true
    }

    /// Read Apple Health into the on-device store under the `apple-health` source, then write NOOP's own
    /// computed metrics back into Health. Safe to call repeatedly (idempotent upserts keyed by day).
    ///
    /// Work is planned by `HealthImportPlan` as 30-day windows, newest first: the last
    /// `HealthImportPlan.recentDays` (90) days, then, until it is complete, the one-time ~14-month history
    /// import, which resumes below the oldest window already saved. Each window's reads run four at a time,
    /// its rows are built off the main actor and saved before the next window starts, and `progress` is
    /// published after every read, so the app stays usable and shows how far the import has got. A locked
    /// iPhone (HealthKit can't be read) pauses the import instead of storing empty answers as data.
    ///
    /// - Parameters:
    ///   - days: calendar days of recent data to refresh; nil picks it: all `recentDays` when started from a
    ///     button or when the last full refresh is over six hours old, else `catchUpDays`.
    ///   - userInitiated: started from a button (shows the floating progress banner).
    ///   - includeHistory: continue the history import if it is unfinished (observer wakes pass false).
    func sync(days: Int? = nil, userInitiated: Bool = false, includeHistory: Bool = true) async {
        guard auth == .authorized else { return }
        guard !syncing else {
            // Asked again while a run is going (the app returning to the foreground, a button): served once
            // the current run ends, if that run had to stop early because the iPhone locked.
            resyncRequested = true
            return
        }
        syncing = true
        pauseRequested = false
        resyncRequested = false
        let outcome = await runImport(days: days, userInitiated: userInitiated, includeHistory: includeHistory)
        progress = nil
        syncing = false
        if outcome == .locked, resyncRequested, UIApplication.shared.applicationState == .active {
            resyncRequested = false
            await sync(days: days, userInitiated: userInitiated, includeHistory: includeHistory)
        }
    }

    private enum ImportOutcome { case finished, paused, locked, failed }

    private func runImport(days: Int?, userInitiated: Bool, includeHistory: Bool) async -> ImportOutcome {
        guard let whoop = await repo.storeHandle() else { return .failed }
        let now = Date()
        let recentDays = days ?? (userInitiated ? HealthImportPlan.recentDays
            : HealthImportPlan.automaticRefreshDays(lastFullRefresh: lastFullRefresh, now: now))
        let windows = HealthImportPlan.plan(
            now: now, routineDays: recentDays, includeHistory: includeHistory,
            historyDone: UserDefaults.standard.bool(forKey: Self.historyDoneKey),
            historySavedFrom: historySavedFrom)
        guard !windows.isEmpty else { return .finished }
        let isHistoryRun = windows.contains(where: \.isHistory)
        let lastRecentIndex = windows.lastIndex(where: { !$0.isHistory })
        let bigRun = windows.count > 1 || userInitiated

        statusNote = nil
        beginBackgroundTime()
        // The history import only reads while the iPhone is unlocked: keep the screen on while NOOP is open.
        if isHistoryRun { ScreenIdle.keepAwake(true) }
        defer {
            if isHistoryRun { ScreenIdle.keepAwake(false) }
            endBackgroundTime()
        }

        let specs = HealthImportReader.statSpecs()
        let readsPerWindow = specs.count + 4            // + glucose, insulin doses, sleep, workouts
        var savedAny = false
        for (index, window) in windows.enumerated() {
            let period = Self.periodLabel(window)
            let report: (Int, String) -> Void = { [weak self] done, step in
                let within = Double(done) / Double(readsPerWindow + 1)
                self?.progress = SyncProgress(fraction: (Double(index) + within) / Double(windows.count),
                                              step: step, period: period, isHistoryImport: isHistoryRun,
                                              userInitiated: userInitiated)
            }
            report(0, specs.first?.group.label ?? "")
            do {
                if pauseRequested { throw CancellationError() }
                let reads = try await readWindow(window, specs: specs, report: report)
                report(readsPerWindow, String(localized: "Saving…"))
                let rows = await Task.detached(priority: .userInitiated) {
                    HealthImportReader.rows(for: window, reads: reads)
                }.value
                try await whoop.upsertAppleDaily(rows.apple, deviceId: appleDeviceId)
                try await whoop.upsertDailyMetrics(rows.daily, deviceId: appleDeviceId)
                try await whoop.upsertMetricSeries(rows.points, deviceId: appleDeviceId)
                if !rows.workouts.isEmpty { try await whoop.upsertWorkouts(rows.workouts, deviceId: appleDeviceId) }
                savedAny = true
                if window.isHistory { noteHistorySaved(from: window.start, now: now) }
                if index == lastRecentIndex, recentDays >= HealthImportPlan.recentDays { lastFullRefresh = now }
                // The newest window first lands on screen right away; the rest follows as it arrives.
                if index == 0, windows.count > 1 { await repo.refresh() }
            } catch HealthImportReader.ReadError.locked {
                statusNote = String(localized: "Paused: Apple Health can't be read while iPhone is locked. The import carries on from where it stopped when you open NOOP again.")
                if savedAny { await repo.refresh() }
                return .locked
            } catch is CancellationError {
                statusNote = String(localized: "Import paused. It carries on from where it stopped next time you open NOOP, or when you tap Resume import.")
                if savedAny { await repo.refresh() }
                return .paused
            } catch {
                lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
                if savedAny { await repo.refresh() }
                return .failed
            }
        }

        // Every window saved: write NOOP's own metrics back into Health, advancing lastSync only when the
        // whole round-trip succeeds (a failed write must not look like a success; PR #375).
        do {
            try await writeBack(whoopStore: whoop)
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
        if bigRun { await repo.refresh() }
        return .finished
    }

    /// Read one window: every daily statistics query plus the raw glucose, insulin, sleep and workout
    /// samples, `parallelReads` at a time, reporting each finished read. A pause request stops it after
    /// the reads in flight (nothing of this window is saved; it is read again next time).
    private static let parallelReads = 4

    private func readWindow(_ window: HealthImportWindow, specs: [HealthImportReader.StatSpec],
                            report: (Int, String) -> Void) async throws -> HealthImportReader.WindowReads {
        enum Job { case stat(Int), glucose, insulin, sleep, workouts }
        enum Output: @unchecked Sendable {
            case stat(Int, [String: HealthImportReader.DayStats])
            case glucose([GlucoseReading]), insulin([InsulinDose]), sleep([SleepStageSample]), workouts([WorkoutRow])
        }
        let hk = store
        let jobs: [Job] = specs.indices.map { Job.stat($0) } + [.glucose, .insulin, .sleep, .workouts]
        func operation(_ job: Job) -> @Sendable () async throws -> Output {
            switch job {
            case .stat(let i):
                let spec = specs[i]
                return { .stat(i, try await HealthImportReader.dailyStatistics(spec, window: window, store: hk)) }
            case .glucose:
                return { .glucose(try await HealthImportReader.glucoseReadings(around: window, store: hk)) }
            case .insulin:
                return { .insulin(try await HealthImportReader.insulinDoses(in: window, store: hk)) }
            case .sleep:
                return { .sleep(try await HealthImportReader.sleepSamples(for: window, store: hk)) }
            case .workouts:
                return { .workouts(try await HealthImportReader.workouts(in: window, store: hk)) }
            }
        }

        var reads = HealthImportReader.WindowReads(stats: Array(repeating: [:], count: specs.count))
        try await withThrowingTaskGroup(of: Output.self) { group in
            var next = 0
            while next < min(Self.parallelReads, jobs.count) {
                group.addTask(operation: operation(jobs[next]))
                next += 1
            }
            var done = 0
            while let output = try await group.next() {
                let step: String
                switch output {
                case .stat(let i, let values): reads.stats[i] = values; step = specs[i].group.label
                case .glucose(let g): reads.glucose = g; step = HealthImportReader.Group.diabetes.label
                case .insulin(let d): reads.insulin = d; step = HealthImportReader.Group.diabetes.label
                case .sleep(let s): reads.sleep = s; step = HealthImportReader.Group.sleep.label
                case .workouts(let w): reads.workouts = w; step = HealthImportReader.Group.workouts.label
                }
                done += 1
                report(done, step)
                if pauseRequested {
                    group.cancelAll()
                    throw CancellationError()
                }
                if next < jobs.count {
                    group.addTask(operation: operation(jobs[next]))
                    next += 1
                }
            }
        }
        return reads
    }

    /// Record that history is saved down to `start`, and mark the history import done once it reaches
    /// the target (about 14 months back).
    private func noteHistorySaved(from start: Date, now: Date) {
        if historySavedFrom.map({ start < $0 }) ?? true {
            UserDefaults.standard.set(start.timeIntervalSince1970, forKey: Self.historySavedFromKey)
        }
        if HealthImportPlan.historyComplete(savedFrom: start, now: now) {
            UserDefaults.standard.set(true, forKey: Self.historyDoneKey)
        }
    }

    /// "27 Jul – 25 Aug 2026": the days a window covers, in the user's locale.
    private static func periodLabel(_ window: HealthImportWindow) -> String {
        let last = window.end.addingTimeInterval(-1)
        return window.start.formatted(.dateTime.day().month(.abbreviated)) + " – "
            + last.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Ask iOS for extra time when the user leaves NOOP mid-import, so the window being read can finish and
    /// be saved. When the time runs out the import is simply suspended with the app and carries on (or
    /// pauses, if the iPhone locked meanwhile) when NOOP comes back.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Apple Health import") { [weak self] in
            // iOS calls this on the main thread, synchronously, and needs the task ended before it returns.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Write back (NOOP → Health)

    /// Write NOOP's strap-derived daily metrics (resting HR, HRV, SpO₂, respiratory rate) into Apple
    /// Health so they appear across the user's Health ecosystem.
    ///
    /// Dedup model: each emitted sample carries a deterministic `HKMetadataKeyExternalUUID` derived
    /// from `noopDeviceId + metric + day`. Before saving, we delete any of *our* prior samples that
    /// carry the same key (scoped to `HKSource.default()` so we never touch another app's data) and
    /// then save the fresh batch. HealthKit assigns a new UUID per save, so the previous strategy
    /// (no metadata, no delete) flooded Health with duplicates on every `sync()`.
    ///
    /// Throws on save failure so the caller can decide whether to advance `lastSync`.
    private func writeBack(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard auth == .authorized else { return }
        let cal = Calendar.current
        let to = HealthKitBridge.dayString(Date())
        guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return }
        let from = HealthKitBridge.dayString(fromDate)
        // Read NOOP's COMPUTED dailies (deviceId + "-noop"), which is the only place a strap-only
        // user's recovery/HRV/RHR/SpO₂/resp lives, then union with any imported `noopDeviceId` rows so
        // a user who ALSO imported a WHOOP export still gets the imported values. Imported overrides
        // computed per day, matching the dashboard's source precedence.
        let computed = (try? await whoopStore.dailyMetrics(deviceId: computedDeviceId, from: from, to: to)) ?? []
        let imported = (try? await whoopStore.dailyMetrics(deviceId: noopDeviceId, from: from, to: to)) ?? []
        var byDay: [String: DailyMetric] = [:]
        for r in computed { byDay[r.day] = r }   // computed first
        for r in imported { byDay[r.day] = r }   // imported overrides
        let rows = byDay.keys.sorted().map { byDay[$0]! }

        struct Candidate { let type: HKQuantityType; let key: String; let sample: HKQuantitySample }
        var candidates: [Candidate] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: String, _ at: Date) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
            let key = "noop:\(noopDeviceId):\(id.rawValue):\(day)"
            let sample = HKQuantitySample(
                type: type,
                quantity: .init(unit: unit, doubleValue: value),
                start: at, end: at,
                metadata: [HKMetadataKeyExternalUUID: key]
            )
            candidates.append(Candidate(type: type, key: key, sample: sample))
        }

        for row in rows {
            guard let date = HealthKitBridge.date(from: row.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            if let rhr = row.restingHr {
                add(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), Double(rhr), row.day, noon)
            }
            if let hrv = row.avgHrv {
                add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), hrv, row.day, noon)
            }
            if let spo2 = row.spo2Pct {
                add(.oxygenSaturation, .percent(), spo2 / 100, row.day, noon)
            }
            if let rr = row.respRateBpm {
                add(.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), rr, row.day, noon)
            }
        }
        guard !candidates.isEmpty else { return }

        // Delete any of OUR prior samples that carry the same metadata keys, then write the fresh
        // batch. Scoped to HKSource.default() so we never touch a sample written by another app
        // that happens to use the same external UUID. Delete failures are non-fatal (e.g., nothing
        // to delete on first run) — only the save throws.
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let grouped = Dictionary(grouping: candidates, by: { $0.type })
        for (type, items) in grouped {
            let keys = Array(Set(items.map { $0.key }))
            let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                    allowedValues: keys)
            let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
            _ = try? await self.store.deleteObjects(of: type, predicate: pred)
        }
        try await self.store.save(candidates.map { $0.sample })
    }

    /// Excludes NOOP's own write-back samples from reads, so the two-way sync never reads its own
    /// output back in as "apple-health" data — which would make the strap and "Apple Health" plot the
    /// same line for a strap-only user, and bias the apple-health average for someone who also has a
    /// watch. `HKSource.default()` is this app's own source. (Reimplemented from @vulnix0x4's PR #375.)
    private static var notNoopAuthored: NSPredicate { HealthImportReader.notNoopAuthored() }

    // MARK: - Diabetes (rich KPIs from raw samples)

    /// On-demand raw CGM readings over `[start, end)`, for one logged WOD's glucose response. Returns
    /// [] unless Health is authorized. ON-DEVICE ONLY — a plain read of samples NOOP did not author.
    func glucoseWindow(start: Date, end: Date) async -> [GlucoseReading] {
        guard auth == .authorized else { return [] }
        return (try? await HealthImportReader.glucoseReadings(from: start, to: end, store: store)) ?? []
    }

    /// On-demand insulin-delivery samples over `[start, end)` (units, epoch-seconds, bolus vs basal),
    /// for the insulin-around-a-WOD view. [] unless authorized. ON-DEVICE ONLY.
    func insulinWindow(start: Date, end: Date) async -> [InsulinEntry] {
        guard auth == .authorized else { return [] }
        guard let type = HKQuantityType.quantityType(forIdentifier: .insulinDelivery) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<[InsulinEntry], Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                var out: [InsulinEntry] = []
                for case let s as HKQuantitySample in samples ?? [] {
                    let bolus: Bool
                    if let num = s.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber,
                       let reason = HKInsulinDeliveryReason(rawValue: num.intValue) {
                        bolus = (reason == .bolus)
                    } else {
                        bolus = true   // untagged → treat as bolus (most hand-logged doses)
                    }
                    out.append(InsulinEntry(ts: s.startDate.timeIntervalSince1970,
                                            units: s.quantity.doubleValue(for: .internationalUnit()),
                                            bolus: bolus))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// On-demand carbohydrate-intake samples over `[start, end)` (grams, epoch-seconds), for the
    /// carbs-around-a-WOD view. [] unless authorized. ON-DEVICE ONLY.
    func carbsWindow(start: Date, end: Date) async -> [CarbEntry] {
        guard auth == .authorized else { return [] }
        guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates) else { return [] }
        let grams = HKUnit.gram()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { (cont: CheckedContinuation<[CarbEntry], Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                var out: [CarbEntry] = []
                for case let s as HKQuantitySample in samples ?? [] {
                    out.append(CarbEntry(ts: s.startDate.timeIntervalSince1970,
                                         grams: s.quantity.doubleValue(for: grams)))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    // MARK: - Workouts (#835)

    /// Source tag stamped on workouts imported from Apple Health. Matches the macOS importer's
    /// `WorkoutSource.appleHealthSource` ("apple-health") and `appleDeviceId`, so the workout list and
    /// source filters treat an iOS-read workout exactly like a macOS-imported one.
    static let appleWorkoutSource = HealthImportReader.workoutSource

    // MARK: - Entitlement detection (#348)

    /// True when this running build actually carries the `com.apple.developer.healthkit` entitlement —
    /// i.e. it can genuinely reach Apple Health. False for a free-Apple-ID / AltStore / Sideloadly
    /// re-sign, which strips the HealthKit capability: the framework links and `isHealthDataAvailable()`
    /// is still true, but `requestAuthorization` is a dead-end and the app can never appear under
    /// Settings › Health › Data Access & Devices.
    ///
    /// Resolution order (most authoritative first), mirroring `IOSDiagnostics`'s profile parse:
    ///  1. If an `embedded.mobileprovision` is present (every dev / sideloaded / TestFlight build ships
    ///     one), slice the wrapped XML plist and look for `com.apple.developer.healthkit` in its
    ///     `Entitlements` dict. A free re-sign re-writes this profile WITHOUT that key. This is the
    ///     definitive signal and is unaffected by whether the user later granted/denied permission.
    ///  2. No embedded profile → an App Store install (App Store strips it). Those are properly signed
    ///     with whatever capabilities the app declares, so treat the entitlement as PRESENT. This is the
    ///     conservative default: it never down-routes a legitimately-signed build, so a user who simply
    ///     denied permission keeps the normal Settings guidance rather than the file-import reroute.
    ///
    /// Computed once and cached: the bundle's profile can't change within a process lifetime.
    static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile = App Store build = properly signed. Assume present.
            return true
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            // Profile present but unparseable — don't claim a missing entitlement off a parse failure;
            // assume present so we never wrongly down-route a real build.
            return true
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        // The key is present (and truthy) on an entitled build; a free re-sign omits it entirely.
        return entitlements["com.apple.developer.healthkit"] != nil
    }()

    // MARK: - Date helpers

    // LOCAL civil day: the rest of the store keys days by the device-local civil day —
    // AppleHealthAggregator.localDay shifts each sample into its own offset, and
    // Repository.dayFormatter leaves timeZone at the default (local) zone. The
    // HKStatisticsCollectionQuery here already buckets in Calendar.current (anchor =
    // startOfDay, interval = 1 day), so labelling those local-midnight bucket starts with a
    // matching local formatter is strictly 1:1; using UTC instead mislabelled a full local day
    // under the previous UTC date for users east of UTC, so apple-health rows never merged with
    // the strap-computed/imported rows for the same civil day.
    // `nonisolated` so the HealthKit query completion handlers — which HealthKit invokes on a private
    // background queue (a nonisolated context) — can label day buckets without a main-actor-isolation
    // warning. They only read a thread-safe DateFormatter, so this is safe off the main actor.
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    nonisolated private static func date(from day: String) -> Date? { dayFormatter.date(from: day) }
}
#endif
