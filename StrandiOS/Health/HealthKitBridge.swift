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
    /// What the running import is doing, for the progress bars. Its own observable object, so a progress
    /// tick re-renders only the progress views, not every screen that observes the bridge (the Apple
    /// Health screen holds many charts); `syncing` above tells those screens when a run starts and ends.
    let importProgress = ImportProgress()

    /// The running import's progress (nil when nothing is running).
    @MainActor
    final class ImportProgress: ObservableObject {
        @Published fileprivate(set) var current: SyncProgress?
    }
    /// A calm status line, not an error: why an import paused, and that it carries on by itself.
    @Published private(set) var statusNote: String?
    /// When NOOP last wrote the strap's data into Apple Health, and what it wrote then.
    @Published private(set) var lastWrite: Date?
    @Published private(set) var lastWriteSummary: String?
    /// Why the last write into Apple Health failed (nil after a successful one).
    @Published private(set) var writeError: String?
    /// Some kinds NOOP writes (heart rate, sleep…) were never offered to the user: `requestAuthorization`
    /// asks for them. The Apple Health screen offers the button.
    @Published private(set) var writePermissionNeeded = false

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

    /// The user's max heart rate (profile), for the heart-rate zones written with each workout.
    private let hrMax: @MainActor () -> Int

    init(repo: Repository, appleDeviceId: String, noopDeviceId: String, hrMax: @escaping @MainActor () -> Int = { 0 }) {
        self.repo = repo
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId
        self.hrMax = hrMax
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
        s.insert(HKObjectType.workoutType())
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
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate,
        // The strap's heart rate, one average per minute (see writeHeartRate).
        .heartRate,
        // NOOP's VO₂max estimate; the energy of the workouts NOOP writes (never a day's total).
        .vo2Max, .activeEnergyBurned
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
            updateWritePermissionNeeded()
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
        // Any write kind granted means the user enabled Apple Health before. Not ALL of them: a kind added
        // later (heart rate) is still undetermined until asked, and must not switch the whole bridge off.
        let granted = writeTypes.contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
        if granted {
            auth = .authorized
            updateWritePermissionNeeded()
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
    /// its rows are built off the main actor and saved before the next window starts, and `importProgress`
    /// is updated after every read, so the app stays usable and shows how far the import has got. A locked
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
        // Write the strap's data into Health first: it doesn't depend on the import, which can run for
        // minutes (the one-time history) and stop early when the iPhone locks.
        await writeToHealth()
        let outcome = await runImport(days: days, userInitiated: userInitiated, includeHistory: includeHistory)
        importProgress.current = nil
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
                self?.importProgress.current = SyncProgress(
                    fraction: (Double(index) + within) / Double(windows.count), step: step, period: period,
                    isHistoryImport: isHistoryRun, userInitiated: userInitiated)
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

        // Every window saved (the write into Health ran at the start of `sync`).
        lastSync = Date()
        lastError = nil
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

    private var writing = false
    private static let newWriteKindsAskedKey = "hkNewWriteKindsAsked.v3"
    private static let workoutsWrittenKey = "hkWorkoutsWritten.v1"
    private static let heartRateNewestKey = "hkHeartRateNewestWritten.v1"
    private static let sleepWrittenKey = "hkSleepWritten.v1"
    /// The strap, as the device the heart rate and sleep came from.
    private static let strapDevice = HKDevice(name: "WHOOP", manufacturer: "WHOOP", model: nil,
                                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                                              localIdentifier: nil, udiDeviceIdentifier: nil)

    private func canWrite(_ type: HKObjectType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    /// True while some kind NOOP writes has never been offered (a kind added after the user said yes).
    private func updateWritePermissionNeeded() {
        writePermissionNeeded = writeTypes.contains { store.authorizationStatus(for: $0) == .notDetermined }
    }

    /// Write the strap's data into Apple Health: the daily resting heart rate, HRV, SpO₂ and respiratory
    /// rate, the heart rate minute by minute, and each night's sleep with its stages. Each kind is written
    /// only if the user allowed it, and each is idempotent: running it again adds only what's missing.
    /// Skipped while the iPhone is locked, when Health can't tell what NOOP already wrote (writing then
    /// could double it). Plans: StrandImport.HealthWritePlan.
    func writeToHealth() async {
        guard !writing, auth == .authorized, UIApplication.shared.isProtectedDataAvailable,
              let whoop = await repo.storeHandle() else { return }
        // One write at a time: two at once could both find the same minutes missing and write them twice.
        writing = true
        defer { writing = false }
        updateWritePermissionNeeded()
        // Kinds added after the user said yes (heart rate): ask once, with NOOP on screen. The system sheet
        // lists only those; the Apple Health screen keeps a button for later.
        if writePermissionNeeded, UIApplication.shared.applicationState == .active,
           !UserDefaults.standard.bool(forKey: Self.newWriteKindsAskedKey) {
            UserDefaults.standard.set(true, forKey: Self.newWriteKindsAskedKey)
            await requestAuthorization()
        }
        var parts: [String] = []
        do {
            let daily = try await writeDailyValues(whoopStore: whoop)
            // Workouts before the heart rate: a workout carries its own minutes of heart rate, which the
            // heart-rate write then finds already there.
            let workouts = try await writeWorkouts()
            let minutes = try await writeHeartRate()
            let nights = try await writeSleep()
            if workouts > 0 { parts.append(String(localized: "workouts: \(workouts)")) }
            if minutes > 0 { parts.append(String(localized: "minutes of heart rate: \(minutes)")) }
            if nights > 0 { parts.append(String(localized: "nights of sleep: \(nights)")) }
            if daily > 0 { parts.append(String(localized: "daily values: \(daily)")) }
            lastWrite = Date()
            if !parts.isEmpty { lastWriteSummary = parts.joined(separator: ", ") }
            writeError = nil
        } catch {
            writeError = String(localized: "Writing to Apple Health failed: \(error.localizedDescription)")
        }
    }

    /// Write NOOP's strap-derived daily metrics (resting HR, HRV, SpO₂, respiratory rate) for the last
    /// `days` days.
    ///
    /// Dedup model: each emitted sample carries a deterministic `HKMetadataKeyExternalUUID` derived
    /// from `noopDeviceId + metric + day`. Before saving, we delete any of *our* prior samples that
    /// carry the same key (scoped to `HKSource.default()` so we never touch another app's data) and
    /// then save the fresh batch. HealthKit assigns a new UUID per save, so the previous strategy
    /// (no metadata, no delete) flooded Health with duplicates on every `sync()`. A day's value is dated
    /// at its noon, or now before noon (Health takes no samples from the future); kinds the user didn't
    /// allow are left out, so one switched-off kind doesn't sink the others. Returns how many it wrote.
    private func writeDailyValues(whoopStore: WhoopStore, days: Int = 14) async throws -> Int {
        let cal = Calendar.current
        let to = HealthKitBridge.dayString(Date())
        guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return 0 }
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
        let now = Date().timeIntervalSince1970
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: String, _ noon: Date) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id), canWrite(type) else { return }
            let key = "noop:\(noopDeviceId):\(id.rawValue):\(day)"
            let at = Date(timeIntervalSince1970: HealthWritePlan.sampleDate(noon: noon.timeIntervalSince1970, now: now))
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
        // VO₂max: the estimate from walks and runs on the days it has one, else the weekly estimate at rest
        // (the two methods aren't mixed within the window). Last 90 days.
        let vo2From = HealthKitBridge.dayString(Date().addingTimeInterval(-90 * 86_400))
        var vo2 = (try? await whoopStore.metricSeries(deviceId: computedDeviceId, key: "vo2max_exercise",
                                                      from: vo2From, to: to)) ?? []
        if vo2.isEmpty {
            vo2 = (try? await whoopStore.metricSeries(deviceId: computedDeviceId, key: "vo2max_est",
                                                      from: vo2From, to: to)) ?? []
        }
        let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        for p in vo2 where p.value > 10 && p.value < 95 {
            guard let date = HealthKitBridge.date(from: p.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            add(.vo2Max, vo2Unit, p.value, p.day, noon)
        }
        guard !candidates.isEmpty else { return 0 }

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
        return candidates.count
    }

    /// Write NOOP's workouts of the last two weeks: the ones the strap recorded or detected and the ones
    /// recorded in NOOP, and each logged WOD. A WOD matching one of those workouts becomes that workout (as
    /// Cross Training, with the WOD's name, result, RX/scaled and RPE); a WOD with no recorded workout is
    /// written over its logged time. Sessions Apple Health already has from another app (an Apple Watch
    /// workout) and imports from other apps (WHOOP, Hevy, files) are left out. Each workout carries its heart
    /// rate minute by minute, its energy when NOOP has it, and the minutes in each heart-rate zone (in its
    /// metadata: Apple Health has no place of its own for zones). A workout is written again only when it
    /// changes; one that no longer exists (a dismissed detected bout) is removed. Returns the workouts written.
    private func writeWorkouts() async throws -> Int {
        let workoutType = HKObjectType.workoutType()
        guard canWrite(workoutType) else { return 0 }
        let now = Date().timeIntervalSince1970
        let rows = await repo.workoutRows(days: HealthWritePlan.workoutDays + 2, reconcileHr: false)
        var own: [WorkoutRow] = []
        var others: [HealthWritePlan.WorkoutSpan] = []
        for r in rows {
            switch WorkoutSource.classify(r.source) {
            case .detected, .manual: own.append(r)
            case .apple: others.append(.init(start: Double(r.startTs), end: Double(r.endTs)))
            case .whoop, .lifting, .activityFile: break      // another app's session: its app writes it
            }
        }
        let oldest = now - Double(HealthWritePlan.workoutDays) * 86_400
        let wods = await repo.allWods().filter { Double($0.ts) >= oldest - 86_400 }
        let wodById = Dictionary(wods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ownSpans = own.map { HealthWritePlan.WorkoutSpan(start: Double($0.startTs), end: Double($0.endTs)) }
        let wodEntries = wods.map { w in
            HealthWritePlan.WodEntry(id: w.id, loggedTs: Double(w.ts),
                                     durationS: (w.resultSeconds ?? w.timeCapS).map(Double.init))
        }
        let plan = HealthWritePlan.workouts(own: ownSpans, others: others, wods: wodEntries, now: now)

        let defaults = UserDefaults.standard
        var written = (defaults.dictionary(forKey: Self.workoutsWrittenKey) as? [String: String]) ?? [:]
        var keep = Set<String>()
        var count = 0
        let zoneFloors = HealthWritePlan.zoneFloors(maxHR: Double(hrMax()))
        for item in plan {
            let row = item.ownIndex.map { own[$0] }
            let itemWods = item.wodIds.compactMap { wodById[$0] }
            let activity = itemWods.isEmpty ? Self.activityType(forSport: row?.sport ?? "") : .crossTraining
            let minutes = await repo.heartRatePerMinute(from: Int(item.start), to: Int(item.end) - 1)
                .filter { HealthWritePlan.plausibleBpm.contains($0.bpm) }
            let zones = zoneFloors.isEmpty ? [] : HealthWritePlan.zoneMinutes(bpm: minutes.map(\.bpm), zoneFloors: zoneFloors)
            let energy = row?.energyKcal.flatMap { $0 > 0 ? $0 : nil }
            let key = "\(Int(item.start))-\(Int(item.end))"
            var metadata: [String: Any] = [HKMetadataKeyExternalUUID: Self.workoutUUID(key)]
            if !itemWods.isEmpty {
                metadata[HKMetadataKeyWorkoutBrandName] = itemWods.map(\.title).joined(separator: " + ")
                metadata["NOOPWod"] = itemWods.map(\.title).joined(separator: " + ")
                let results = itemWods.compactMap { w in WodFormat.progressionValue(w).map { WodFormat.progressionLabel($0, kind: w.resultKind) } }
                if !results.isEmpty { metadata["NOOPWodResult"] = results.joined(separator: " + ") }
                let rx = itemWods.compactMap(\.rx)
                if !rx.isEmpty { metadata["NOOPWodRX"] = rx.allSatisfy { $0 } ? "RX" : "Scaled" }
                if let rpe = itemWods.compactMap(\.rpe).max() { metadata["NOOPRPE"] = NSNumber(value: rpe) }
            }
            if let strain = row?.strain { metadata["NOOPEffort"] = NSNumber(value: strain) }
            for (zone, mins) in zones.enumerated() where zone > 0 {
                metadata["NOOPZone\(zone)Minutes"] = NSNumber(value: mins)
            }
            let fingerprint = HealthWritePlan.fingerprint([
                "\(Int(item.start))", "\(Int(item.end))", "\(activity.rawValue)", "\(minutes.count)",
                "\(energy ?? 0)", zones.map(String.init).joined(separator: ","),
                (metadata["NOOPWod"] as? String) ?? "", (metadata["NOOPWodResult"] as? String) ?? "",
                (metadata["NOOPWodRX"] as? String) ?? "", "\((metadata["NOOPRPE"] as? NSNumber)?.doubleValue ?? 0)",
            ])
            keep.insert(key)
            guard written[key] != fingerprint else { continue }
            try await removeOwnWorkout(key: key, start: item.start, end: item.end, withSamples: true)
            try await saveWorkout(activity: activity, start: item.start, end: item.end, minutes: minutes,
                                  energyKcal: energy, metadata: metadata)
            written[key] = fingerprint
            count += 1
        }
        // A workout NOOP wrote that no longer exists (a dismissed or re-detected bout): remove exactly that
        // one, by its id (a new version of it may overlap the same time).
        for key in Array(written.keys) where !keep.contains(key) {
            let start = key.split(separator: "-").first.flatMap { Double($0) } ?? 0
            if start >= oldest { try await removeOwnWorkout(key: key, start: 0, end: 0, withSamples: false) }
            written[key] = nil
        }
        defaults.set(written, forKey: Self.workoutsWrittenKey)
        return count
    }

    private static func workoutUUID(_ key: String) -> String { "noop:workout:\(key)" }

    /// Remove the workout NOOP wrote under `key` (found by its id, so an overlapping workout of NOOP's is never
    /// touched) and, when it is about to be written again over [start, end], NOOP's heart rate in that time
    /// (the new workout carries it again) and the energy NOOP wrote inside it.
    private func removeOwnWorkout(key: String, start: Double, end: Double, withSamples: Bool) async throws {
        let own = HKQuery.predicateForObjects(from: HKSource.default())
        try await deleteOwn(HKObjectType.workoutType(), NSCompoundPredicate(andPredicateWithSubpredicates: [
            own, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                             allowedValues: [Self.workoutUUID(key)]),
        ]))
        guard withSamples else { return }
        let from = Date(timeIntervalSince1970: start), to = Date(timeIntervalSince1970: end)
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate), canWrite(hr) {
            try await deleteOwn(hr, NSCompoundPredicate(andPredicateWithSubpredicates: [
                own, HKQuery.predicateForSamples(withStart: from, end: to, options: [])]))
        }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), canWrite(energy) {
            try await deleteOwn(energy, NSCompoundPredicate(andPredicateWithSubpredicates: [
                own, HKQuery.predicateForSamples(withStart: from, end: to, options: [.strictStartDate, .strictEndDate])]))
        }
    }

    /// Build and save one workout with its heart rate (minute by minute) and energy.
    private func saveWorkout(activity: HKWorkoutActivityType, start: Double, end: Double, minutes: [HRBucket],
                             energyKcal: Double?, metadata: [String: Any]) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: Self.strapDevice)
        let startDate = Date(timeIntervalSince1970: start), endDate = Date(timeIntervalSince1970: end)
        var samples: [HKSample] = []
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate), canWrite(hr) {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            for m in minutes {
                let s = max(Double(m.ts), start), e = min(Double(m.ts) + 59, end)
                guard e > s else { continue }
                samples.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpm, doubleValue: m.bpm),
                                                start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e),
                                                device: Self.strapDevice, metadata: nil))
            }
        }
        if let kcal = energyKcal, let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), canWrite(type) {
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                            start: startDate, end: endDate, device: Self.strapDevice, metadata: nil))
        }
        try await Self.run { builder.beginCollection(withStart: startDate, completion: $0) }
        if !samples.isEmpty { try await Self.run { builder.add(samples, completion: $0) } }
        try await Self.run { builder.addMetadata(metadata, completion: $0) }
        try await Self.run { builder.endCollection(withEnd: endDate, completion: $0) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.finishWorkout { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Await a HealthKit call that reports (success, error).
    private static func run(_ call: (@escaping (Bool, Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            call { ok, error in
                if let error { cont.resume(throwing: error) }
                else if ok { cont.resume() }
                else { cont.resume(throwing: HKError(.errorInvalidArgument)) }
            }
        }
    }

    /// The Apple Health workout type for a sport name (NOOP's, a WHOOP sport, or a hand-typed one).
    static func activityType(forSport sport: String) -> HKWorkoutActivityType {
        let s = sport.lowercased()
        func has(_ words: String...) -> Bool { words.contains { s.contains($0) } }
        if has("crossfit", "wod", "functional", "cross training", "crosstraining") { return .crossTraining }
        if has("hiit", "interval") { return .highIntensityIntervalTraining }
        if has("run", "jog") { return .running }
        if has("walk") { return .walking }
        if has("hik") { return .hiking }
        if has("cycl", "bike", "biking", "spin") { return .cycling }
        if has("swim") { return .swimming }
        if has("row") { return .rowing }
        if has("strength", "weight", "lift", "gym") { return .traditionalStrengthTraining }
        if has("yoga") { return .yoga }
        if has("pilates") { return .pilates }
        if has("box") { return .boxing }
        if has("elliptical") { return .elliptical }
        if has("stair") { return .stairClimbing }
        if has("dance") { return .cardioDance }
        if has("tennis") { return .tennis }
        if has("soccer", "football") { return .soccer }
        if has("basketball") { return .basketball }
        if has("climb") { return .climbing }
        if has("ski") { return .downhillSkiing }
        return .other
    }

    /// Write the strap's heart rate, one average per minute, for the minutes Health doesn't have from NOOP
    /// yet: the last two weeks the first time, then from three days behind the newest minute written (so
    /// data the strap offloads late still gets in), a day per read and save. Returns the minutes written.
    private func writeHeartRate() async throws -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate), canWrite(type) else { return 0 }
        let defaults = UserDefaults.standard
        let newest = defaults.object(forKey: Self.heartRateNewestKey) as? Double
        guard let window = HealthWritePlan.heartRateWindow(now: Date().timeIntervalSince1970,
                                                           newestWritten: newest) else { return 0 }
        let unit = HKUnit.count().unitDivided(by: .minute())
        var written = 0
        var newestSeen = newest ?? 0
        for chunk in HealthWritePlan.chunks(from: window.from, to: window.to) {
            let minutes = await repo.heartRatePerMinute(from: Int(chunk.from), to: Int(chunk.to) - 1)
            guard let last = minutes.last else { continue }
            let have = try await minutesWritten(of: type, from: chunk.from, to: chunk.to)
            let missing = HealthWritePlan.missingMinutes(minutes.map { (ts: Double($0.ts), bpm: $0.bpm) },
                                                         alreadyWritten: have)
            if !missing.isEmpty {
                let samples = missing.map { m in
                    HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: m.bpm),
                                     start: Date(timeIntervalSince1970: m.ts),
                                     end: Date(timeIntervalSince1970: m.ts + 59),
                                     device: Self.strapDevice, metadata: nil)
                }
                try await store.save(samples)
                written += samples.count
            }
            newestSeen = max(newestSeen, Double(last.ts))
            defaults.set(newestSeen, forKey: Self.heartRateNewestKey)
        }
        return written
    }

    /// The minutes (`Int(ts) / 60`) of heart rate NOOP already wrote in [from, to). Throws when Health
    /// can't answer, so a run never writes blind and doubles what's there.
    private func minutesWritten(of type: HKQuantityType, from: Double, to: Double) async throws -> Set<Int> {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: from),
                                        end: Date(timeIntervalSince1970: to), options: .strictStartDate),
        ])
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: Set((samples ?? []).map { Int($0.startDate.timeIntervalSince1970) / 60 }))
            }
            store.execute(q)
        }
    }

    /// Write each night of the last two weeks that has ended: in bed from its onset to its end, plus its
    /// stages (light as Apple's "core"). A night is written again only when it changed (it grew, its onset
    /// was corrected, it was staged again): NOOP's earlier samples for it are removed first. Returns the
    /// nights written.
    private func writeSleep() async throws -> Int {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis), canWrite(type) else { return 0 }
        let defaults = UserDefaults.standard
        var written = (defaults.dictionary(forKey: Self.sleepWrittenKey) as? [String: String]) ?? [:]
        let now = Date().timeIntervalSince1970
        let oldest = now - Double(HealthWritePlan.sleepDays) * 86_400
        let sessions = await repo.allSleepSessions(days: HealthWritePlan.sleepDays + 2)
        var nights = 0
        for s in sessions where Double(s.endTs) <= now - 600 && Double(s.endTs) >= oldest {
            let start = Double(s.effectiveStartTs), end = Double(s.endTs)
            let key = String(s.startTs)
            let fingerprint = HealthWritePlan.sleepFingerprint(start: start, end: end, stagesJSON: s.stagesJSON)
            guard written[key] != fingerprint else { continue }
            let segments = HealthWritePlan.sleepSegments(start: start, end: end, stagesJSON: s.stagesJSON)
            guard !segments.isEmpty else { continue }
            // Remove what NOOP wrote for this night before (an earlier version of it, or an earlier install).
            var lo = min(start, Double(s.startTs)), hi = end
            if let old = written[key].flatMap(HealthWritePlan.span(ofFingerprint:)) {
                lo = min(lo, old.start); hi = max(hi, old.end)
            }
            let previous = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(from: HKSource.default()),
                HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: lo),
                                            end: Date(timeIntervalSince1970: hi),
                                            options: [.strictStartDate, .strictEndDate]),
            ])
            try await deleteOwn(type, previous)
            let samples = segments.map { seg in
                HKCategorySample(type: type, value: Self.sleepValue(seg.kind),
                                 start: Date(timeIntervalSince1970: seg.start),
                                 end: Date(timeIntervalSince1970: seg.end),
                                 device: Self.strapDevice, metadata: nil)
            }
            try await store.save(samples)
            written[key] = fingerprint
            nights += 1
        }
        // Forget nights too old to be written again.
        written = written.filter { (Double($0.key) ?? 0) >= oldest - 7 * 86_400 }
        defaults.set(written, forKey: Self.sleepWrittenKey)
        return nights
    }

    /// Delete NOOP's own samples matching `predicate`. Nothing to delete is fine: HealthKit reports it as
    /// an error (no data), which must not stop the write.
    private func deleteOwn(_ type: HKObjectType, _ predicate: NSPredicate) async throws {
        do {
            _ = try await store.deleteObjects(of: type, predicate: predicate)
        } catch {
            let ns = error as NSError
            guard ns.domain == HKErrorDomain, ns.code == HKError.Code.errorNoData.rawValue else { throw error }
        }
    }

    private static func sleepValue(_ kind: HealthWritePlan.SleepKind) -> Int {
        switch kind {
        case .inBed: return HKCategoryValueSleepAnalysis.inBed.rawValue
        case .awake: return HKCategoryValueSleepAnalysis.awake.rawValue
        case .core: return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .deep: return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .rem: return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
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
