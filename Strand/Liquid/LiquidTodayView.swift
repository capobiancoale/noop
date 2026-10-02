//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  Three blocks, then the rest behind "Details":
//    1. Your state: the three scores (Charge, Effort, Rest) as liquid vessels, a one-word verdict and one
//       sentence under them, what each flagging signal says, and why a score is still missing today.
//    2. Glucose now (when Apple Health has CGM readings): the latest reading, its trend arrow, the last
//       three hours and the day's time in range. Informational only.
//    3. Today's workout: the day's latest session with its Effort, heart-rate zones, the glucose around it
//       and its WOD, and the actions it needs (log the WOD, rename or dismiss a detected one).
//  Details (collapsed until opened, remembered): live heart rate, the Heart & Glucose timeline, recovery
//  vitals, key metrics, Charge vs Effort, the week, glucose & insulin, your cards and data sources. Every
//  value binds to the SAME real data the classic TodayView reads, and every tap routes to the same public
//  destination. The sky is a fixed, full-bleed background (edge-to-edge under the status bar, does not
//  scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics
import StrandImport

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    #if os(iOS)
    // Apple Health, iOS only — the intraday glucose/carbs/insulin behind the "Heart & Glucose" chart.
    // Absent on macOS (HealthKitBridge lives in the iOS target), where that chart never shows. Read through,
    // never observed: the bridge's sync status mustn't redraw Today (HealthBridgeEnvironment.swift).
    @Environment(\.healthBridge) private var health
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vitality: Double?           // exploreSeries("vitality").last
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    @State private var workouts: [WorkoutRow] = [] // newest-first
    @State private var sparks: [String: [Double]] = [:]  // KEY METRICS 14-day trend series, computed once in load()
    @State private var recStrain: [DayScore] = []         // Recovery vs Strain, last 30 days
    // "Heart & Glucose" intraday cross chart. HR + workout bands come from the store (cross-platform);
    // glucose/carbs/bolus come from Apple Health (iOS only) and stay empty on macOS ⇒ the section hides.
    @State private var crossWorkouts: [TimelineBand] = []
    @State private var crossGlucose: [GlucoseReading] = []
    @State private var crossTrace = GlucoseTrace(readings: [])
    /// The selected day's window (midnight to now for today) and the chart's zoom inside it.
    @State private var crossBounds: ClosedRange<Date> = Date()...Date().addingTimeInterval(3_600)
    @State private var crossZoom: ClosedRange<Date>?
    @State private var crossCarbs: [CarbEntry] = []
    @State private var crossBolus: [InsulinEntry] = []
    // Consensus hypoglycaemia events overnight (00:00–05:59 or during the main sleep ending on the selected
    // day), from Apple Health on iOS. Drives the night-time low note under the scores; empty ⇒ hidden.
    @State private var nightLows: [HypoEvent] = []
    // Diabetes recap (apple-health, day-keyed to the selected day). Nil ⇒ the row/section is hidden,
    // never a fabricated zero. Populated from the apple-health metric series in load().
    @State private var glucoseAvg: Double?         // glucose_avg
    @State private var glucoseTir: Double?         // glucose_tir (%)
    @State private var carbsToday: Double?         // carbs_g (apple-health)
    @State private var insulinToday: Double?       // insulin_total (U)

    // Week-in-review (last 7 days), computed once in load().
    @State private var weekTir: Double?
    @State private var weekGlucoseAvg: Double?
    @State private var weekStrain: Double?
    @State private var weekWods = 0

    // Block 2, glucose now (Apple Health, iOS): the latest reading and its trend, the selected day's figures,
    // and the last three hours for the small chart. Nil / empty ⇒ the block hides.
    @State private var glucoseNow: GlucoseNow?
    @State private var glucoseDay: GlucoseDayStats?
    @State private var glucoseSpark: [GlucoseTrace.Point] = []
    @State private var glucoseSparkWindow: ClosedRange<Double> = 0...1

    // Block 3, the selected day's workout: its sessions newest first, and for the newest one its minutes in
    // heart-rate zones 1…5, the WODs logged for it and the glucose around it.
    @State private var dayWorkouts: [WorkoutRow] = []
    @State private var workoutZones: [Double]?
    @State private var workoutWods: [WodLogRow] = []
    @State private var workoutGlucose: WorkoutGlucose?
    @State private var confirmDismissWorkout = false

    // sheets / expanders
    @State private var guideSection: ScoreSection?
    @State private var showCustomise = false
    @State private var showSettings = false
    @State private var showSupport = false
    @State private var synthesisExpanded = false
    @State private var showLiveSession = false
    @State private var showWodEditor = false
    /// Everything past the three blocks, folded until the user opens it (remembered across launches).
    @AppStorage("liquidToday.detailsExpanded") private var detailsExpanded = false

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    /// Where the Heart & Glucose timeline sits, in the scroll view's space: a sideways drag that starts on
    /// it moves, zooms or reads the chart, so it must not also change the day. A reference box, so keeping
    /// it current while the page scrolls never re-renders the screen.
    @State private var swipeExclusion = SwipeExclusion()
    @State private var showDayPicker = false

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// Nights banked toward Charge's baseline while it is still being learned (nil once Charge exists or on
    /// a past day), resolved in load(): it scans repo.days.
    @State private var chargeCalibrationNights: Int?
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = Color(.sRGB, red: 0x9b / 255, green: 0x7b / 255, blue: 0xff / 255, opacity: 1)
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    /// Hero card fill: a translucent near-black so it floats over the sky (mock rgba(13,14,20,.78)).
    private let heroFill = Color(.sRGB, red: 13 / 255, green: 14 / 255, blue: 20 / 255, opacity: 0.80)

    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            if repo.today?.day == selectedDayKey { return repo.today }
            return repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        // #1013: these must localize — the header showed English "Today"/"Yesterday"/weekday even when the
        // system UI (tab bar etc.) was another language. "Today"/"Yesterday" go through String(localized:)
        // (matching the classic TodayView.dayNavLabel), and the weekday name is formatted in the user's
        // locale, not the en_US_POSIX one used only for machine day-keys.
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(Locale.autoupdatingCurrent))
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (left = older, right = newer), clamped to [today, earliest].
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .named(Self.pullSpace))
            .onEnded { value in
                // A drag that starts on the Heart & Glucose timeline belongs to the chart.
                guard !swipeExclusion.rects.contains(where: { $0.contains(value.startLocation) }) else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                liquidRefreshIndicator   // grows in the revealed space; a vessel filling with the pull

                VStack(alignment: .leading, spacing: 12) {
                    #if os(iOS)
                    AthleteCheckInCard(day: selectedDayKey, recovery: displayDay?.recovery)
                        .id(selectedDayKey)
                    #endif
                    scene                                   // block 1: the scores and what they mean
                    Text("Charge is an experimental estimate. Open Understand your signals for sources and limits.")
                        .font(.caption).foregroundStyle(.secondary)
                    #if os(iOS)
                    AthleteReviewCard(day: selectedDayKey)
                        .id(selectedDayKey)
                    #endif
                    if !nightLows.isEmpty { nightLowSection }  // qualifies Charge, so it sits right under it
                    if hasGlucoseBlock { glucoseNowSection }    // block 2
                    todayWorkoutSection                         // block 3
                    detailsToggle
                    if detailsExpanded {
                        heartRateSection
                        if hasTodayCross { todayCrossSection }
                        recoveryVitalsSection
                        keyMetricsSection
                        if hasRecStrain { recoveryStrainSection }
                        if hasWeekData { weekSummarySection }
                        if hasGlucoseToday { glucoseTodaySection }
                        yourCardsSection
                        dataSourcesSection
                    }
                    Color.clear.frame(height: 90) // floating tab-bar clearance
                }
                .padding(.horizontal, 16)
                .padding(.top, 30) // sit the title lower into the sky, not jammed under the status bar
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .coordinateSpace(name: Self.pullSpace)
        .onPreferenceChange(PullOffsetKey.self) { handlePull($0) }
        .onPreferenceChange(DaySwipeExclusionKey.self) { swipeExclusion.rects = $0 }
        // The sky is a FIXED full-bleed backdrop drawn behind the scroll content, edge-to-edge under the
        // status bar. A ScrollView background does not scroll with the content, so pulling down never
        // moves the sky (the exact behaviour the scaffold uses on the classic Today).
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                // Reduce-motion (and low-power) users get the same sky posed still — no twinkle/breath.
                // Also static until the first data load settles, so launch isn't fighting a live sky too.
                Group {
                    if reduceMotion || !dataLoaded { LiquidSkyStatic(hour: liveHour) }
                    else { LiquidSky(hour: liveHour) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 340, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)") { await load() }
        #if os(iOS)
        // Glucose now stays current while Today is on screen: Loop writes a CGM reading to Apple Health every
        // few minutes, and the next full reload (a strap sync) may be further off than that.
        .task(id: selectedDayOffset) {
            guard selectedDayOffset == 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshGlucose()
            }
        }
        // Log the WOD of the day's workout, dated when the workout started.
        .sheet(isPresented: $showWodEditor) {
            WodEditorView(existing: nil,
                          initialDate: dayWorkouts.first.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) }) {
                Task { await load() }
            }
        }
        #endif
        .confirmationDialog("Not a workout?", isPresented: $confirmDismissWorkout, titleVisibility: .visible) {
            Button("Hide this activity", role: .destructive) {
                if let w = dayWorkouts.first { dismissWorkout(w) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NOOP stops showing it as a workout. Its heart rate stays in your day.")
        }
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        .sheet(isPresented: $showCustomise) {
            DashboardCardsEditorSheet(selectionRaw: $dashboardCardsRaw)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // The heart → the (optional) Support sheet: NOOP is free forever, donations just help it keep moving.
        .sheet(isPresented: $showSupport) {
            NavigationStack {
                SupportView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSupport = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Reserves the revealed space at the top and shows a vessel that fills with the pull, then sloshes
    /// while the refresh runs.
    private var liquidRefreshIndicator: some View {
        let progress = min(1, max(0, pullY / pullThreshold))
        return ZStack {
            if refreshing {
                LiquidVessel(value: 0.6, tint: liquidHeart, animated: true)
                    .frame(width: 34, height: 34)
            } else if pullY > 2 {
                LiquidVessel(value: progress, tint: liquidHeart, animated: false)
                    .frame(width: 30, height: 30)
                    .opacity(progress)
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: refreshing ? 64 : min(pullY, pullThreshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: refreshing)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        pullY = max(0, y)
        guard !refreshing else { return }
        if pullY >= pullThreshold, !refreshArmed {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, pullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                await repo.refresh()
                await load()
                try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
                withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
            }
        }
    }

    // MARK: - Scene (sky title + controls + hero)

    private var scene: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button { showDayPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayTitle)
                            .font(StrandFont.rounded(28))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 1)
                        Text(dateLine)
                            .font(StrandFont.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
                .popover(isPresented: $showDayPicker) {
                    DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                               displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .frame(minWidth: 320, minHeight: 360)
                        .liquidPopoverAdaptation()
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    // Support / donate — a tap opens the (optional) support sheet. NOOP is free forever.
                    Button { showSupport = true } label: {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .frame(width: 34, height: 34)
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Support NOOP. It's free; donations are optional and help development.")
                    // Profile pic (the one set in Settings) → opens Settings, matching the classic Today.
                    Button { showSettings = true } label: {
                        ProfileAvatarView(imageData: profile.avatarImageData, size: 34)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Profile and settings")
                    LiquidAddButton()
                    LiquidBatteryButton()
                }
            }
            // Subtle NOOP wordmark in the sky between header and hero. Perfectly centred (a letter row has
            // no trailing tracking gap the way `Text(...).tracking()` does), with a tap easter egg.
            if selectedDayOffset > 0 {
                // Days back (a swipe or the calendar): one tap returns to today.
                Button {
                    withAnimation(StrandMotion.interactive) { selectedDayOffset = 0 }
                } label: {
                    Label("Back to today", systemImage: "arrow.uturn.forward")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(LiquidPressStyle())
                .padding(.top, 10)
            }
            LiquidWordmark()
                .padding(.top, 30)
            heroCard.padding(.top, 22)
        }
    }

    /// One-tap Live Session start (silent guardian, beta), in today's workout block: where a session starts.
    private var liveSessionButton: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                Text("Start session")
                Text("BETA")
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .modifier(ActionChip(tint: StrandPalette.metricCyan))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    /// Block 1: the three scores, and under them what they add up to (`stateVerdict`), in one card.
    private var heroCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 4) {
                HeroScoreCell(label: "Charge", score: displayDay?.recovery, tint: StrandPalette.chargeColor,
                              pill: "WHOOP", animated: dataLoaded, onGuide: { guideSection = .charge })
                HeroScoreCell(label: "Effort", score: displayDay?.strain, tint: StrandPalette.effortColor,
                              pill: nil, animated: dataLoaded, onGuide: { guideSection = .effort })
                HeroScoreCell(label: "Rest", score: restScore, tint: StrandPalette.restColor,
                              pill: "WHOOP", animated: dataLoaded, onGuide: { guideSection = .rest })
            }
            stateVerdict
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(heroFill)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.11), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        )
        // The card is dark in both themes, so its colours resolve as on a dark screen: the light theme's
        // deeper tints would sit too dark on it.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Block 1: the verdict under the scores

    /// A one-word verdict and one sentence on the day, the signals behind it when opened, and while a score
    /// is still missing today, why, so an empty gauge never reads as broken. Inside the hero card, which is
    /// dark in both themes, so the text uses the on-dark tokens.
    private var stateVerdict: some View {
        let signals = readiness.signals
        return VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { synthesisExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    if let word = readinessWord {
                        Text(word)
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(verdictTint)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(verdictTint.opacity(0.16))
                                .overlay(Capsule().strokeBorder(verdictTint.opacity(0.35), lineWidth: 1)))
                            .fixedSize()
                    }
                    Text(synthLine)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.onDarkPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !signals.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.onDarkTertiary)
                            .rotationEffect(.degrees(synthesisExpanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(signals.isEmpty)
            .accessibilityHint(signals.isEmpty ? Text(verbatim: "") : Text("Shows the signals behind it"))
            if synthesisExpanded {
                ForEach(signals, id: \.key) { signalRow($0) }
                    .transition(.opacity)
            }
            ForEach(Array(missingScoreNotes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.onDarkTertiary)
                    note
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    /// One readiness signal: a dot in its state's colour, what it is, what it says, and its figures. Built
    /// from the signal's key and state rather than the engine's English sentence, so it reads in the app's
    /// language.
    private func signalRow(_ s: ReadinessEngine.Signal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(signalTint(s.flag)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                signalLabel(s)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                signalDetail(s)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let figures = signalFigures(s) {
                Text(verbatim: figures)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.onDarkTertiary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func signalLabel(_ s: ReadinessEngine.Signal) -> Text {
        switch s.key {
        case "hrv": return Text(verbatim: "HRV")
        case "rhr": return Text("Resting HR")
        case "respRate": return Text("Respiratory rate")
        case "acwr": return Text("Training load")
        case "monotony": return Text("Training variety")
        default: return Text(verbatim: s.label)
        }
    }

    private func signalDetail(_ s: ReadinessEngine.Signal) -> Text {
        switch (s.key, s.flag) {
        case ("hrv", .good): return Text("Above your baseline")
        case ("hrv", .watch): return Text("A little below your baseline")
        case ("hrv", .bad): return Text("Well below your baseline")
        case ("rhr", .good): return Text("At or below your baseline")
        case ("rhr", .watch): return Text("A little above your baseline")
        case ("rhr", .bad): return Text("Well above your baseline")
        case ("respRate", .bad): return Text("Above your baseline, sometimes an early sign of illness")
        case ("respRate", _): return Text("A little above your baseline")
        case ("monotony", _): return Text("A similar load every day")
        case ("acwr", _):
            let ratio = readiness.acwr ?? 1
            if ratio < 0.8 { return Text("Lighter than usual: room to build") }
            if ratio < 1.3 { return Text("In line with your usual load") }
            if ratio < 1.5 { return Text("Building fast: watch for fatigue") }
            return Text("Well above your usual load")
        default: return Text("In your normal range")
        }
    }

    /// The figures behind a signal: tonight against the baseline for the vitals, the week's load against the
    /// month's for training load.
    private func signalFigures(_ s: ReadinessEngine.Signal) -> String? {
        switch s.key {
        case "hrv", "rhr", "respRate": return s.evidence
        case "acwr": return readiness.acwr.map { String(format: "%.2f", $0) }
        default: return nil
        }
    }

    private func signalTint(_ flag: ReadinessEngine.Flag) -> Color {
        switch flag {
        case .good: return StrandPalette.statusPositive
        case .neutral: return StrandPalette.onDarkTertiary
        case .watch: return StrandPalette.statusWarning
        case .bad: return StrandPalette.statusCritical
        }
    }

    private var verdictTint: Color {
        switch readiness.level {
        case .strained, .rundown: return StrandPalette.statusWarning
        default: return StrandPalette.chargeColor
        }
    }

    /// Why a score is missing on today, one line each: Charge while its baseline is still being learned (or
    /// before last night is in), Effort before the strap has recorded the day, Rest before a night is scored.
    /// Only for today: on a past day a missing score is missing data.
    private var missingScoreNotes: [Text] {
        guard selectedDayOffset == 0, dataLoaded else { return [] }
        var notes: [Text] = []
        if displayDay?.recovery == nil {
            if let n = chargeCalibrationNights {
                notes.append(Text("Charge is learning your baseline: \(n) of \(Baselines.minNightsSeed) nights."))
            } else {
                notes.append(Text("Charge appears once last night's sleep is in from the strap."))
            }
        }
        if displayDay?.strain == nil {
            notes.append(Text("Effort builds up as the strap records your day."))
        }
        if restScore == nil {
            notes.append(Text("Rest appears after a night's sleep with the strap."))
        }
        return notes
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(spacing: 8) {
            sectionHead("HEART RATE", trailing: Text("Live"))
            // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
            // Show all → Deep Timeline. Make the live HR card a one-tap route into it, with a visible
            // "Full day" affordance so it's discoverable again. (This comment used to claim the Deep
            // Timeline already drew sleep + activity bands — it didn't at the time; the #979 spin-off
            // added that parity in FullDayChartView.)
            NavigationLink { FullDayChartView() } label: {
                card {
                    VStack(spacing: 10) {
                        // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY
                        // this card, never the whole Today. Shows the current bpm live with a rolling
                        // beat-by-beat trace; falls back to today's banked 5-minute trace when idle.
                        LiquidLiveHR(tint: liquidHeart, fallback: hrValues, animated: dataLoaded)
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Full day").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint("Opens the full-day heart rate timeline")
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("YOUR CARDS").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { showCustomise = true } label: {
                    Text("CUSTOMISE").font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live.
            ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)) { card in
                liquidCard(for: card)
            }
        }
    }

    /// One "Your cards" row for a given card type — honours the user's CUSTOMISE selection + order.
    /// Wired cards show real values; the rest render "–" for now (they still appear, so add/remove/
    /// reorder is reflected). stress → Stress screen, sleep → Sleep, everything else → Health.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardLink(dest: StressView(), title: card.title, sub: card.subtitle,
                     value: stressText, tint: StrandPalette.accent, frac: fracOver(stress, 3))
        case .fitnessAge:
            cardLink(dest: metricDetail("fitness_age"), title: card.title, sub: card.subtitle,
                     value: unitText(fitnessAge, card.unit), tint: StrandPalette.chargeColor, frac: 0.5)
        case .vitality:
            cardLink(dest: metricDetail("vitality"), title: card.title, sub: card.subtitle,
                     value: intText(vitality), tint: liquidPurple, frac: frac(vitality))
        case .hrv:
            cardLink(dest: metricDetail("hrv"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.avgHrv, card.unit), tint: StrandPalette.metricCyan,
                     frac: fracOver(displayDay?.avgHrv, 120))
        case .restingHr:
            cardLink(dest: metricDetail("rhr"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                     tint: StrandPalette.metricRose, frac: fracOver(displayDay?.restingHr.map(Double.init), 100))
        case .respiratory:
            cardLink(dest: metricDetail("resp_rate"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                     tint: StrandPalette.accent, frac: fracOver(displayDay?.respRateBpm, 24))
        case .steps:
            cardLink(dest: metricDetail("steps_est"), title: card.title, sub: card.subtitle,
                     value: stepsText, tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            // Not wired to a real read yet — render EMPTY (not half-full) so it doesn't imply a reading.
            cardLink(dest: metricDetail("spo2"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .skinTemp:
            cardLink(dest: metricDetail("skin_temp"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            cardLink(dest: metricDetail("active_kcal"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .sleep:
            cardLink(dest: SleepView(), title: card.title, sub: card.subtitle,
                     value: sleepText, tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            cardLink(dest: HydrationView(), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .coupled:
            // A tap-through to the full Coupled day screen. No value.
            cardLink(dest: CoupledView(), title: card.title, sub: card.subtitle,
                     value: "", tint: StrandPalette.chargeColor, frac: 0.6)
        }
    }

    /// The per-metric detail page (its own data screen with chart + history), looked up by catalog key.
    /// Each card opens ITS metric (2026-07-02: not the shared Health screen). Falls back to Health
    /// only if the key is somehow absent from the catalog.
    @ViewBuilder
    private func metricDetail(_ key: String) -> some View {
        if let m = MetricCatalog.all.first(where: { $0.key == key }) {
            MetricDetailView(metric: m)
        } else {
            HealthView()
        }
    }

    private func cardLink<Dest: View>(dest: Dest, title: String, sub: String,
                                      value: String, tint: Color, frac: Double?) -> some View {
        NavigationLink { dest } label: {
            HStack(spacing: 12) {
                LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(value).font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: - Block 2: glucose now

    /// Shown when Apple Health has CGM readings for the selected day (so on iOS only), so people without a
    /// CGM never see an empty glucose card.
    private var hasGlucoseBlock: Bool { glucoseDay != nil }

    /// Today: the latest reading with its trend arrow and age, the last three hours, and the day so far. A
    /// past day: its figures and its trace. Informational only, never a treatment surface: Apple Health can
    /// lag the CGM, and the CGM app and Loop stay the source of truth.
    private var glucoseNowSection: some View {
        VStack(spacing: 8) {
            sectionHead(selectedDayOffset == 0 ? "GLUCOSE NOW" : "GLUCOSE", trailing: Text(verbatim: "Apple Health"))
            card {
                VStack(alignment: .leading, spacing: 12) {
                    if let now = glucoseNow { glucoseNowRow(now) }
                    if glucoseSpark.count >= 2 {
                        VStack(alignment: .leading, spacing: 4) {
                            GlucoseSparkline(points: glucoseSpark, window: glucoseSparkWindow)
                                .equatable()
                                .frame(height: 64)
                            Text(selectedDayOffset == 0 ? "Last 3 hours" : "The whole day")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    if let day = glucoseDay {
                        HStack(alignment: .top, spacing: 12) {
                            glucoseStat("Time in range", value: "\(Int(day.tirPct.rounded()))%")
                            glucoseStat("Average", value: "\(Int(day.mean.rounded())) mg/dL")
                            glucoseStat("Lows", value: "\(day.hypoEvents)")
                        }
                    }
                    Text("From your CGM in Apple Health. Informational only, not medical advice.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The latest reading, its range and its trend arrow; re-drawn once a minute so its age stays true
    /// between reloads, and shown as the last reading (no arrow) once it is too old to be "now".
    private func glucoseNowRow(_ now: GlucoseNow) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = now.isStale(now: context.date.timeIntervalSince1970)
            let tint = stale ? StrandPalette.textSecondary : glucoseTint(now.mgdl)
            HStack(alignment: .center, spacing: 10) {
                (Text(verbatim: "\(Int(now.mgdl.rounded()))").font(StrandFont.rounded(40))
                    + Text(verbatim: " mg/dL").font(StrandFont.caption))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                if !stale, let trend = now.trend {
                    GlucoseTrendArrow(trend: trend).foregroundStyle(tint)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(glucoseRangeWord(now.mgdl))
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(verbatim: glucoseAge(now, at: context.date))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .multilineTextAlignment(.trailing)
            }
        }
    }

    private func glucoseStat(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(verbatim: value).font(StrandFont.number(16)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Below the target range in the critical colour, above it in the warning colour, always with the word.
    private func glucoseTint(_ mgdl: Double) -> Color {
        if mgdl < GlucoseTrace.lowThreshold { return StrandPalette.statusCritical }
        if mgdl > 180 { return StrandPalette.statusWarning }
        return StrandPalette.textPrimary
    }

    /// The consensus ranges (Battelino et al., Diabetes Care 2019): below 54, below 70, 70–180, above 180,
    /// above 250 mg/dL.
    private func glucoseRangeWord(_ mgdl: Double) -> LocalizedStringKey {
        if mgdl < 54 { return "Very low" }
        if mgdl < 70 { return "Below range" }
        if mgdl <= 180 { return "In range" }
        if mgdl <= 250 { return "Above range" }
        return "Very high"
    }

    private func glucoseAge(_ now: GlucoseNow, at date: Date) -> String {
        let seconds = date.timeIntervalSince1970 - now.ts
        if now.isStale(now: date.timeIntervalSince1970) {
            let clock = Date(timeIntervalSince1970: now.ts).formatted(date: .omitted, time: .shortened)
            return String(localized: "Last reading \(clock)")
        }
        let minutes = Int(seconds / 60)
        return minutes < 1 ? String(localized: "just now") : String(localized: "\(minutes) min ago")
    }

    /// Re-reads today's glucose from Apple Health between full reloads (every two minutes while Today is on
    /// screen), and only touches the view state when a new reading arrived.
    private func refreshGlucose() async {
        #if os(iOS)
        guard selectedDayOffset == 0, let health else { return }
        let start = crossBounds.lowerBound
        let readings = await health.glucoseWindow(start: start, end: Date())
        guard readings.count != crossGlucose.count || readings.last?.ts != crossGlucose.last?.ts else { return }
        crossGlucose = readings
        crossTrace = GlucoseTrace(readings: readings)
        updateGlucoseBlocks()
        #endif
    }

    /// Block 2's figures and the glucose around block 3's workout, from the loaded day's readings.
    private func updateGlucoseBlocks() {
        glucoseDay = DiabetesMetrics.glucoseDaily(crossGlucose).values.max { $0.readings < $1.readings }
        if selectedDayOffset == 0 {
            glucoseNow = GlucoseNow.latest(crossGlucose)
            let end = Date().timeIntervalSince1970
            glucoseSparkWindow = (end - 3 * 3_600)...end
        } else {
            glucoseNow = nil
            glucoseSparkWindow = crossBounds.lowerBound.timeIntervalSince1970...crossBounds.upperBound.timeIntervalSince1970
        }
        glucoseSpark = crossTrace.visible(from: glucoseSparkWindow.lowerBound, to: glucoseSparkWindow.upperBound)
        workoutGlucose = dayWorkouts.first.flatMap {
            WorkoutGlucose.around(crossTrace, start: Double($0.startTs), end: Double($0.endTs))
        }
    }

    // MARK: - Block 3: today's workout

    /// The selected day's latest session: what it was, when, its Effort, its heart-rate zones, the glucose
    /// around it and its WOD, with the actions it needs. Tapping it opens the workout.
    private var todayWorkoutSection: some View {
        VStack(spacing: 8) {
            sectionHead(selectedDayOffset == 0 ? "TODAY'S WORKOUT" : "WORKOUT",
                        trailing: dayWorkouts.count > 1 ? Text("\(dayWorkouts.count) sessions") : nil)
            card {
                if let w = dayWorkouts.first { workoutBlock(w) } else { noWorkoutBlock }
            }
            NavigationLink { WorkoutsView() } label: {
                HStack(spacing: 4) {
                    Text("All workouts").font(StrandFont.subhead)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(StrandPalette.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func workoutBlock(_ w: WorkoutRow) -> some View {
        let detected = WorkoutSource.classify(w.source) == .detected
        return VStack(alignment: .leading, spacing: 14) {
            NavigationLink { WorkoutDetailView(row: w) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(LocalizedStringKey(WorkoutSource.displaySport(w.sport)))
                                    .font(StrandFont.number(17))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                if detected { SourceBadge("Detected", tint: StrandPalette.metricPurple) }
                            }
                            Text(verbatim: workoutTimes(w))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer(minLength: 8)
                        (Text(verbatim: effortText(w.strain)).font(StrandFont.number(17))
                            + Text(verbatim: " EFFORT").font(StrandFont.overlineScaled(9)))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    LiquidTube(frac: (w.strain ?? 0) / 100, tint: StrandPalette.effortColor, height: 10, animated: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the workout")
            if let zones = workoutZones { HRZoneSplitView(minutes: zones) }
            if let g = workoutGlucose { workoutGlucoseRow(g) }
            #if os(iOS)
            ForEach(workoutWods) { wod in wodRow(wod) }
            #endif
            if detected { detectedPrompt(w) }
            workoutActions
        }
    }

    private var noWorkoutBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedDayOffset == 0 ? "No workout yet today." : "No workout on this day.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Train with the strap on and NOOP finds the session from your heart rate.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            workoutActions
        }
    }

    /// Glucose at the start and at the end, and a note when it went below 70 during it or in the hour after.
    private func workoutGlucoseRow(_ g: WorkoutGlucose) -> some View {
        let start = g.startMgdl.map { String(Int($0.rounded())) } ?? "–"
        let end = g.endMgdl.map { String(Int($0.rounded())) } ?? "–"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Glucose, start → end").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text(verbatim: "\(start) → \(end) mg/dL").font(StrandFont.number(15))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize()
            }
            if g.wentLow, let low = g.lowestMgdl {
                Label {
                    Text("Below 70 mg/dL during it or in the hour after, lowest \(Int(low.rounded())) mg/dL.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
            }
        }
    }

    #if os(iOS)
    /// A WOD logged for this workout, opening its own screen (glucose around it, progression).
    private func wodRow(_ wod: WodLogRow) -> some View {
        NavigationLink { WodDetailView(wod: wod, onChanged: { Task { await load() } }) } label: {
            HStack(spacing: 10) {
                Image(systemName: "figure.strengthtraining.functional")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "WOD").font(StrandFont.overlineScaled(9)).tracking(1.2)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(verbatim: wod.title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let result = WodFormat.result(wod) {
                    Text(verbatim: result).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    /// A detected session asks what it was: rename it to a sport, or say it wasn't a workout.
    private func detectedPrompt(_ w: WorkoutRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOOP found this from your heart rate. What was it?")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { renameMenu(w); notAWorkoutButton }
                VStack(alignment: .leading, spacing: 8) { renameMenu(w); notAWorkoutButton }
            }
        }
    }

    private func renameMenu(_ w: WorkoutRow) -> some View {
        Menu {
            ForEach(WorkoutsView.relabelSports, id: \.self) { sport in
                Button { relabel(w, to: sport) } label: { Text(LocalizedStringKey(sport)) }
            }
        } label: {
            Label("Rename", systemImage: "pencil").modifier(ActionChip(tint: StrandPalette.accent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var notAWorkoutButton: some View {
        Button { confirmDismissWorkout = true } label: {
            Label("Not a workout", systemImage: "xmark").modifier(ActionChip(tint: StrandPalette.textSecondary))
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// A WOD can be logged here (iOS, where the WOD log lives) while none is logged for the session yet.
    private var canLogWod: Bool {
        #if os(iOS)
        return workoutWods.isEmpty
        #else
        return false
        #endif
    }

    /// Log the WOD and, today, start a live session.
    @ViewBuilder private var workoutActions: some View {
        let logWod = canLogWod
        let live = liveSessionsBeta && selectedDayOffset == 0
        if logWod || live {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { workoutActionButtons(logWod: logWod, live: live) }
                VStack(alignment: .leading, spacing: 8) { workoutActionButtons(logWod: logWod, live: live) }
            }
        }
    }

    @ViewBuilder private func workoutActionButtons(logWod: Bool, live: Bool) -> some View {
        if logWod {
            Button { showWodEditor = true } label: {
                Label("Log WOD", systemImage: "plus").modifier(ActionChip(tint: StrandPalette.effortColor))
            }
            .buttonStyle(LiquidPressStyle())
        }
        if live { liveSessionButton }
    }

    private func relabel(_ w: WorkoutRow, to sport: String) {
        Task { await repo.relabelDetected(w, sport: sport); await load() }
    }

    private func dismissWorkout(_ w: WorkoutRow) {
        Task { await repo.dismissDetected(w); await load() }
    }

    /// "18:02–19:05 · 63 min · 540 kcal".
    private func workoutTimes(_ w: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(w.startTs)).formatted(date: .omitted, time: .shortened)
        let end = Date(timeIntervalSince1970: TimeInterval(w.endTs)).formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end) · " + workoutSub(w)
    }

    /// A workout's imported zone split (the source's own percentages) as minutes, which the workout screen
    /// prefers over one derived from the strap's samples.
    private static func importedZoneMinutes(_ w: WorkoutRow) -> [Double]? {
        guard let pct = WorkoutZones.percents(w.zonesJSON) else { return nil }
        let minutes = (w.durationS ?? Double(w.endTs - w.startTs)) / 60
        return minutes > 0 ? pct.map { minutes * $0 / 100 } : nil
    }

    /// The WODs logged for a workout: those whose logged time resolves to it, by the same rule the WOD screen
    /// uses to find its workout (`WodTimeWindow.resolve` over the sessions recorded within half a day).
    static func wods(for w: WorkoutRow, among wods: [WodLogRow], workouts: [WorkoutRow]) -> [WodLogRow] {
        wods.filter { wod in
            let logged = Double(wod.ts)
            guard abs(logged - Double(w.startTs)) < 12 * 3_600 else { return false }
            let spans = workouts
                .filter { abs(Double($0.startTs) - logged) < 12 * 3_600 }
                .map { (start: Double($0.startTs), end: Double($0.endTs)) }
            let window = WodTimeWindow.resolve(loggedTs: logged,
                                               durationS: (wod.resultSeconds ?? wod.timeCapS).map(Double.init),
                                               workouts: spans)
            return window.recorded && window.start == Double(w.startTs) && window.end == Double(w.endTs)
        }
    }

    // MARK: - Details (folded)

    private var detailsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { detailsExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Details").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Heart rate, vitals, key metrics, the week, your cards and data sources")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .rotationEffect(.degrees(detailsExpanded ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .padding(.top, 4)
        .accessibilityValue(detailsExpanded ? Text("Shown") : Text("Hidden"))
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        // PER-FIELD, today-first carry: each vital reads today's own value, else falls back to the prior
        // day that recorded it (`vitalsDay`). Coalesce ONCE so the number and its fill fraction agree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let line = vitalsProvenanceLine {
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                vitalRow("Heart-rate variability", unitText(hrv, "ms"),
                         StrandPalette.metricCyan, fracOver(hrv, 120))
                vitalRow("Resting heart rate", unitText(rhr, "bpm"),
                         StrandPalette.metricRose, fracOver(rhr, 100))
                vitalRow("Breaths per minute", unitText(resp, "rpm", decimals: 1),
                         StrandPalette.accent, fracOver(resp, 24))
            }
        }
    }

    private func vitalRow(_ label: LocalizedStringKey, _ value: String, _ tint: Color, _ frac: Double?) -> some View {
        HStack(spacing: 12) {
            LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 26, height: 26)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Night-time low (Charge can't see it)

    /// A consensus night-time hypoglycaemia event (Battelino et al., Lancet Diabetes Endocrinol 2023) flags
    /// Charge: heart rate and HRV often stay flat through a spontaneous nocturnal hypo (Koivikko et al.,
    /// Diabetes Care 2012), so an HRV-led recovery score can read normal after one. Lows at night are also
    /// more likely after exercise (EASD/ISPAD position statement, Moser et al., Diabetologia 2020).
    /// Informational only — it never suggests carbs or insulin.
    private var nightLowSection: some View {
        let worstLevel = nightLows.map(\.level).max() ?? 1
        let minutes = Int(nightLows.reduce(0) { $0 + $1.durationMin }.rounded())
        let nadir = Int((nightLows.map(\.nadir).min() ?? 0).rounded())
        let first = nightLows.map(\.start).min() ?? 0
        let last = nightLows.map(\.end).max() ?? 0
        let clock = Date(timeIntervalSince1970: first).formatted(date: .omitted, time: .shortened)
            + "–" + Date(timeIntervalSince1970: last).formatted(date: .omitted, time: .shortened)
        let exercisedBefore = workouts.contains { Double($0.endTs) <= first && Double($0.endTs) >= first - 18 * 3_600 }
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(StrandPalette.statusWarning)
                    Text("NIGHT-TIME LOW").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(worstLevel >= 2 ? String(localized: "Level 2") : String(localized: "Level 1"))
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(worstLevel >= 2 ? StrandPalette.statusCritical : StrandPalette.statusWarning)
                }
                Text(nightLows.count == 1
                     ? String(localized: "Below 70 mg/dL for \(minutes) min, lowest \(nadir) mg/dL, \(clock).")
                     : String(localized: "\(nightLows.count) lows, \(minutes) min below 70 mg/dL in total, lowest \(nadir) mg/dL, \(clock)."))
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                if nightLows.contains(where: \.extended) {
                    Text("It lasted more than 2 hours.").font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                }
                Text("Heart rate and HRV often stay flat through a night-time low, so Charge can read normal after one. Weigh how you actually feel today.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                if exercisedBefore {
                    Text("Night-time lows are more likely after exercise, especially in the afternoon or evening.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                Text("From your CGM in Apple Health. Informational only, not medical advice.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - Glucose recap (apple-health)

    /// True when the selected day carries any diabetes data — gates the whole recap card so users
    /// without glucose/insulin/carbs in Apple Health never see it.
    private var hasGlucoseToday: Bool { glucoseAvg != nil || carbsToday != nil || insulinToday != nil }

    /// Diabetes recap on Today: glucose average, time-in-range, carbs and insulin for the selected day,
    /// read from Apple Health (an AID app such as Loop). READ-ONLY / informational — Health lags the
    /// CGM/pump, so this is never a treatment surface. Each row shows only when its value is present.
    private var glucoseTodaySection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("GLUCOSE & INSULIN").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("Apple Health").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if glucoseAvg != nil {
                    vitalRow("Glucose (avg)", unitText(glucoseAvg, "mg/dL"),
                             StrandPalette.metricRose, fracOver(glucoseAvg, 250))
                }
                if glucoseTir != nil {
                    vitalRow("Time in range", unitText(glucoseTir, "%"),
                             StrandPalette.metricCyan, glucoseTir.map { max(0, min(1, $0 / 100)) })
                }
                if carbsToday != nil {
                    vitalRow("Carbs", unitText(carbsToday, "g"),
                             StrandPalette.metricAmber, fracOver(carbsToday, 300))
                }
                if insulinToday != nil {
                    vitalRow("Insulin", unitText(insulinToday, "U", decimals: 1),
                             StrandPalette.accent, fracOver(insulinToday, 60))
                }
            }
        }
    }

    // MARK: - Key metrics grid

    private var hasWeekData: Bool { weekTir != nil || weekGlucoseAvg != nil || weekStrain != nil || weekWods > 0 }

    /// Week-in-review card: last-7-day Time-in-Range, average glucose, logged WODs and mean strain — a
    /// quick dashboard read. Each stat shows "—" when its data is absent (never a fabricated zero).
    private var weekSummarySection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("THIS WEEK").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("7 days").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                    weekStat("Time in range", weekTir.map { "\(Int($0.rounded()))%" }, StrandPalette.metricCyan)
                    weekStat("Avg glucose", weekGlucoseAvg.map { "\(Int($0.rounded())) mg/dL" }, StrandPalette.metricRose)
                    weekStat("WODs", weekWods > 0 ? "\(weekWods)" : nil, StrandPalette.effortColor)
                    weekStat("Avg Effort", weekStrain.map { effortText($0) }, StrandPalette.effortColor)
                }
            }
        }
    }

    private func weekStat(_ label: LocalizedStringKey, _ value: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value ?? "—").font(StrandFont.number(18))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mean of the last ≤7 values of a daily series; nil when empty.
    private static func mean7(_ series: [(day: String, value: Double)]) -> Double? {
        let vals = series.suffix(7).map(\.value)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Charge vs Effort (30-day trend)

    private var hasRecStrain: Bool { recStrain.filter { $0.recovery != nil || $0.strain != nil }.count >= 2 }

    private var recoveryStrainSection: some View {
        VStack(spacing: 8) {
            sectionHead("CHARGE vs EFFORT", trailing: Text("30 days"))
            card {
                VStack(alignment: .leading, spacing: 10) {
                    RecoveryStrainChart(points: recStrain)
                    HStack(spacing: 16) {
                        legendDot(StrandPalette.chargeColor, Text(verbatim: "Charge"))
                        legendDot(StrandPalette.effortColor, Text(verbatim: "Effort"))
                    }
                }
            }
        }
    }

    private func legendDot(_ c: Color, _ label: Text) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 8, height: 8)
            label.font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: Heart & Glucose (intraday cross)

    /// Show only when there's a real intraday glucose trace (≥2 readings) — that's the series this chart
    /// exists for and the one the top heart-rate section doesn't already cover. Always false on macOS
    /// (no Apple Health), so the section is iOS-only in practice without needing a compile guard here.
    private var hasTodayCross: Bool { crossGlucose.count >= 2 }

    private var todayCrossSection: some View {
        VStack(spacing: 8) {
            sectionHead("HEART & GLUCOSE", trailing: crossTrailing)
            card {
                VStack(alignment: .leading, spacing: 10) {
                    #if os(iOS)
                    // Glucose, heart rate and carbs / boluses in lanes on the day's clock, zoomable down to
                    // single minutes (heart rate re-read at the zoom's resolution, as on the Deep Timeline).
                    GlucoseHeartTimeline(glucose: crossTrace, carbs: crossCarbs, boluses: crossBolus,
                                         bands: crossWorkouts, bounds: crossBounds, axis: .clock,
                                         hrMax: profile.hrMax > 0 ? Double(profile.hrMax) : nil,
                                         loadHeart: { await crossHeart($0) }, zoom: $crossZoom,
                                         surface: StrandPalette.surfaceRaised)
                    #endif
                    Text("Informational only, not medical advice. Carb and insulin choices stay with you and your care team / Loop.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .background {
                // The chart's own drags (move, zoom, read) must not also swipe the day.
                GeometryReader { g in
                    Color.clear.preference(key: DaySwipeExclusionKey.self,
                                           value: [g.frame(in: .named(Self.pullSpace))])
                }
            }
        }
    }

    /// The strap's heart rate for the chart's window, at the resolution its zoom needs: about one point per
    /// point of the chart's width (more would only cost drawing time).
    private func crossHeart(_ window: ClosedRange<Date>) async -> HeartTrace {
        let s = await repo.timelineSeries(metric: .hr, from: Int(window.lowerBound.timeIntervalSince1970),
                                          to: Int(window.upperBound.timeIntervalSince1970), targetPoints: 360)
        return HeartTrace(points: s.points, isRaw: s.isRaw, bucketSeconds: s.bucketSeconds)
    }

    /// The section overline's right-hand tag: "today" / "yesterday" / a short date for older days.
    private var crossTrailing: Text {
        switch selectedDayOffset {
        case 0: return Text("today")
        case 1: return Text("yesterday")
        default:
            return Text(verbatim: selectedLogicalDay.formatted(
                .dateTime.day().month(.abbreviated).locale(Locale.autoupdatingCurrent)))
        }
    }

    private var keyMetricsSection: some View {
        // HRV / Rest HR tiles share the recovery vitals' per-field today-first carry so they don't blank at
        // the rollover while Recovery/Strain/Sleep stay strictly today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(spacing: 8) {
            sectionHead("KEY METRICS", trailing: Text("14-day trend"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                // Charge and Effort are the scores' names in every language, as on the hero.
                ktile(Text(verbatim: "Charge"), intText(displayDay?.recovery), "%", StrandPalette.chargeColor, frac(displayDay?.recovery), spark: sparks["recovery"] ?? [])
                ktile(Text(verbatim: "Effort"), intText(displayDay?.strain), "", StrandPalette.effortColor, frac(displayDay?.strain), spark: sparks["strain"] ?? [])
                ktile(Text("Sleep"), sleepText, "", StrandPalette.restColor, fracOver(displayDay?.totalSleepMin, 480), spark: sparks["sleep"] ?? [])
                ktile(Text(verbatim: "HRV"), intText(hrv), "ms", StrandPalette.metricCyan, fracOver(hrv, 120), spark: sparks["hrv"] ?? [])
                ktile(Text("Rest HR"), intText(rhr), "bpm", StrandPalette.metricRose, fracOver(rhr, 100), spark: sparks["rhr"] ?? [])
                ktile(Text("Steps"), stepsText, "", StrandPalette.chargeColor, fracOver(stepCount, 10000), spark: sparks["steps"] ?? [])
            }
            NavigationLink { MetricExplorerView() } label: {
                Text("Show all metrics").font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity).padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    /// Last ≤14 present values of a daily field, oldest→newest, for a KEY METRIC sparkline.
    private static func spark14(_ days: [DailyMetric], _ pick: (DailyMetric) -> Double?) -> [Double] {
        Array(days.compactMap(pick).suffix(14))
    }

    private func ktile(_ label: Text, _ value: String, _ unit: String, _ tint: Color,
                       _ frac: Double?, spark: [Double] = []) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label.font(StrandFont.overlineScaled(9)).tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
            (Text(value).font(StrandFont.number(17))
                + Text(unit.isEmpty ? "" : " \(unit)").font(StrandFont.caption))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // A 14-day sparkline when there's enough history (the "14-day trend" the header promises),
            // else the single-value tube for metrics without a series yet.
            if spark.count >= 2 {
                Sparkline(values: spark,
                          gradient: Gradient(colors: [tint.opacity(0.55), tint]),
                          showsHead: false, showsHover: false)
                    .frame(height: 22)
            } else {
                LiquidTube(frac: frac ?? 0, tint: tint, height: 8, animated: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        )
    }

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(spacing: 8) {
            sectionHead("DATA SOURCES", trailing: Text("Provenance"))
            NavigationLink { DataSourcesView() } label: {
                card {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Synced from").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("View sources").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        LiquidStrapBatteryRow()
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Reusable chrome

    private func sectionHead(_ title: LocalizedStringKey, trailing: Text? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            if let trailing {
                trailing.font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
    }

    // MARK: - Data

    private func load() async {
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: selectedDayKey)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        // Staleness cap for today's carry-forwards: a vital / step / glucose value older than this is NOT
        // shown as "today" — otherwise a days-old reading (e.g. an HR from when the strap was last worn)
        // reads as a current one when the user hasn't recorded today. 2 days keeps the legitimate
        // overnight-rollover carry (yesterday's vitals before tonight scores) while dropping anything
        // older to an honest "—". Same spirit as the `freshRestScore` gate already applied to Rest.
        let freshCutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        if let v = cachedVitalsDay, v.day < freshCutoff { cachedVitalsDay = nil }
        chargeCalibrationNights = selectedDayOffset == 0
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv), hasRecovery: day?.recovery != nil)
            : nil

        // KEY METRICS 14-day trend series — computed ONCE here (repo.days is large; never in body).
        sparks = [
            "recovery": Self.spark14(repo.days) { $0.recovery },
            "strain":   Self.spark14(repo.days) { $0.strain },
            "sleep":    Self.spark14(repo.days) { $0.totalSleepMin },
            "hrv":      Self.spark14(repo.days) { $0.avgHrv },
            "rhr":      Self.spark14(repo.days) { $0.restingHr.map(Double.init) },
            "steps":    Self.spark14(repo.days) { $0.steps.map(Double.init) },
        ]
        // Recovery vs Strain, last 30 days (for the home trend chart).
        recStrain = repo.days.suffix(30).map {
            DayScore(id: $0.day, date: Self.dayKeyParser.date(from: $0.day) ?? Date(),
                     recovery: $0.recovery, strain: $0.strain)
        }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()
        // Diabetes recap series (apple-health). Daily metrics, so day-keyed like steps below.
        async let gAvgA = repo.series(key: "glucose_avg", source: "apple-health")
        async let gTirA = repo.series(key: "glucose_tir", source: "apple-health")
        async let carbA = repo.series(key: "carbs_g", source: "apple-health")
        async let insA  = repo.series(key: "insulin_total", source: "apple-health")
        async let wodsA = repo.allWods()

        let restSeries = await restA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value
        fitnessAge = (await fitA).last?.value   // history-wide latest banked (not day-scoped)
        vitality = (await vitA).last?.value
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsSeries = await stepsA
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last.flatMap { $0.day >= freshCutoff ? $0.value : nil } : nil)
        let hrBucketsDay = await hrA
        hrValues = hrBucketsDay.map { $0.bpm }
        workouts = await wkA

        // Block 3: the day's sessions (started inside its window), newest first; for the newest, its minutes
        // in heart-rate zones from the strap and the WODs logged for it.
        dayWorkouts = workouts.filter { $0.startTs >= from && $0.startTs < to }.sorted { $0.startTs > $1.startTs }
        let allWods = await wodsA
        if let w = dayWorkouts.first {
            // Zones as the workout screen shows them: an imported split first, else the strap's own samples.
            if let imported = Self.importedZoneMinutes(w) {
                workoutZones = imported
            } else {
                workoutZones = await repo.workoutZoneMinutes(from: w.startTs, to: w.endTs, maxHR: profile.hrMax)
            }
            workoutWods = Self.wods(for: w, among: allWods, workouts: workouts)
        } else {
            workoutZones = nil
            workoutWods = []
        }

        // "Heart & Glucose" timeline for the selected day: workout bands are the day's sessions clipped to
        // the window; the chart reads heart rate itself at its zoom's resolution. Glucose/carbs/bolus are
        // read live from Apple Health on iOS (empty on macOS, where the section never shows).
        crossWorkouts = workouts
            .filter { $0.endTs >= from && $0.startTs <= to }
            .map { TimelineBand(start: Date(timeIntervalSince1970: TimeInterval($0.startTs)),
                                end: Date(timeIntervalSince1970: TimeInterval($0.endTs)), label: nil) }
        #if os(iOS)
        let winStart = Date(timeIntervalSince1970: TimeInterval(from))
        let winEnd = Date(timeIntervalSince1970: TimeInterval(to))
        crossGlucose = (await health?.glucoseWindow(start: winStart, end: winEnd)) ?? []
        crossTrace = GlucoseTrace(readings: crossGlucose)
        // A new day opens un-zoomed; a refresh of the same day keeps the zoom.
        if crossBounds.lowerBound != winStart { crossZoom = nil }
        crossBounds = winStart...max(winEnd, winStart.addingTimeInterval(3_600))
        crossCarbs = (await health?.carbsWindow(start: winStart, end: winEnd)) ?? []
        crossBolus = ((await health?.insulinWindow(start: winStart, end: winEnd)) ?? []).filter { $0.bolus }
        // Night-time lows for the note under the scores: consensus events (Battelino 2023) that began
        // 00:00–05:59 or during the main sleep ending on this day. Read from 18:00 the evening before.
        let nightFrom = from - 6 * 3_600
        let nightTo = min(from + 12 * 3_600, Int(Date().timeIntervalSince1970))
        let nightGlucose = (await health?.glucoseWindow(start: Date(timeIntervalSince1970: TimeInterval(nightFrom)),
                                                        end: Date(timeIntervalSince1970: TimeInterval(nightTo)))) ?? []
        let mainSleep = repo.sleeps
            .filter { $0.endTs > nightFrom && $0.endTs <= from + 14 * 3_600 }
            .max { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) }
        nightLows = DiabetesMetrics.overnightEvents(
            DiabetesMetrics.hypoEvents(nightGlucose, tzOffsetSeconds: TimeZone.current.secondsFromGMT()),
            sleepStart: mainSleep.map { Double($0.startTs) }, sleepEnd: mainSleep.map { Double($0.endTs) })
        #endif
        updateGlucoseBlocks()

        // Day-key each diabetes series to the selected day (they're daily), with a latest fallback only
        // at offset 0 — mirrors stepsEst above. A missing day stays nil so the row simply doesn't show.
        func dayKeyed(_ s: [(day: String, value: Double)]) -> Double? {
            let byDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            if let v = byDay[selectedDayKey] { return v }
            // Carry the latest reading onto today only when it's recent (freshCutoff); a days-old glucose
            // value must not read as today's. Older ⇒ nil ⇒ the row/section hides.
            guard selectedDayOffset == 0, let last = s.last, last.day >= freshCutoff else { return nil }
            return last.value
        }
        let gAvgSeries = await gAvgA
        let gTirSeries = await gTirA
        glucoseAvg = dayKeyed(gAvgSeries)
        glucoseTir = dayKeyed(gTirSeries)
        carbsToday = dayKeyed(await carbA)
        insulinToday = dayKeyed(await insA)

        // Week-in-review (last 7 days): TIR/avg glucose from the same series, mean strain from
        // repo.days, and the count of logged WODs in the window.
        weekGlucoseAvg = Self.mean7(gAvgSeries)
        weekTir = Self.mean7(gTirSeries)
        let strain7 = repo.days.compactMap { $0.strain }.suffix(7)
        weekStrain = strain7.isEmpty ? nil : strain7.reduce(0, +) / Double(strain7.count)
        let sevenAgo = Int(Date().timeIntervalSince1970) - 7 * 86_400
        weekWods = allWods.filter { $0.ts >= sevenAgo }.count

        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + signals). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    /// The verdict's word. "Recover", not "Rest": Rest is a score's name.
    private var readinessWord: LocalizedStringKey? {
        switch readiness.level {
        case .primed: return "Aligned"
        case .balanced: return "Usual range"
        case .strained, .rundown: return "Changed"
        case .insufficient: return nil
        }
    }

    private var synthLine: LocalizedStringKey {
        switch readiness.level {
        case .primed: return "Your recorded signals are aligned. Compare them with how you feel."
        case .balanced: return "Your recorded signals are near their usual range."
        case .strained: return "Some signals differ from your baseline."
        case .rundown: return "Several signals differ from your baseline. Review your check-in and recent sessions."
        case .insufficient: return "Still learning your baseline. A few more nights and this fills in."
        }
    }

    private var stepCount: Double? { displayDay?.steps.map(Double.init) ?? stepsEst }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "–" }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String { stress.map { String(Int($0.rounded())) } ?? "Calibrating" }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "–" }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 { parts.append(String(format: "%.1f km", dm / 1000)) }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private var dateLine: String {
        // #1013: localize the sub-header date. The old en_US_POSIX "EEEE, d MMMM" formatter forced English
        // weekday + month names regardless of the UI language. A locale-aware field template localizes both
        // the names AND the field order (e.g. fr "mercredi 4 juillet") in the user's locale.
        return selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(Locale.autoupdatingCurrent))
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

/// The frames (in the Today scroll's space) of views whose own sideways drags must not change the day.
private final class SwipeExclusion {
    var rects: [CGRect] = []
}

private struct DaySwipeExclusionKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - NOOP wordmark (centred, with a tap easter egg)

/// The subtle NOOP wordmark. Built as a row of letters (not `Text(...).tracking()`, which adds a
/// trailing gap after the last glyph and pushes the word off-centre), so it sits DEAD centre. Tap it
/// for a little easter egg: it plays one of several random one-shot animations — wiggle, shake, flip,
/// spin, bounce, or a jelly squash — with a light haptic.
private struct LiquidWordmark: View {
    @State private var rot = 0.0      // z-rotation (wiggle / spin)
    @State private var scaleX = 1.0   // horizontal scale (jelly squash)
    @State private var scaleY = 1.0   // vertical scale (bounce / jelly)
    @State private var dx = 0.0       // horizontal offset (shake)
    @State private var flip = 0.0     // y-axis 3D flip
    @State private var token = 0      // drives the tap haptic

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array("NOOP".enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(StrandFont.rounded(16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .rotationEffect(.degrees(rot))
        .scaleEffect(x: scaleX, y: scaleY)
        .offset(x: dx)
        .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { playRandomEgg() }
        .liquidTapHaptic(trigger: token)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The easter egg: one of several one-shot animations at random. The oscillating ones (wiggle/shake/
    /// squash) kick the value to an extreme then let an under-damped spring settle it back through zero,
    /// which reads as a natural wobble without hand-authored keyframes.
    private func playRandomEgg() {
        token &+= 1
        switch Int.random(in: 0..<6) {
        case 0: // wiggle
            rot = -14
            withAnimation(.spring(response: 0.5, dampingFraction: 0.28)) { rot = 0 }
        case 1: // shake
            dx = -12
            withAnimation(.spring(response: 0.45, dampingFraction: 0.26)) { dx = 0 }
        case 2: // flip
            withAnimation(.easeInOut(duration: 0.6)) { flip += 360 }
        case 3: // spin
            withAnimation(.easeInOut(duration: 0.55)) { rot += 360 }
        case 4: // bounce
            scaleX = 1.28; scaleY = 1.28
            withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { scaleX = 1; scaleY = 1 }
        default: // jelly (squash + stretch)
            scaleX = 1.35; scaleY = 0.7
            withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) { scaleX = 1; scaleY = 1 }
        }
    }
}

// MARK: - Hero score cell (count-up number over a filling vessel, tap-to-splash)

/// One of the three hero scores (Charge / Effort / Rest). The vessel fills from empty and the number
/// COUNTS UP to the value when data lands; tapping the gauge itself splashes (the number is
/// hit-transparent so the tap reaches the vessel). The label row taps through to the scoring guide.
private struct HeroScoreCell: View {
    let label: String
    let score: Double?            // 0–100 (nil = no data yet)
    let tint: Color
    let pill: String?
    let animated: Bool
    let onGuide: () -> Void

    @State private var shown: Double = 0

    private var frac: Double? { score.map { max(0, min(1, $0 / 100)) } }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                LiquidVessel(value: frac, tint: tint, animated: animated)
                    .frame(width: 96, height: 96)
                Group {
                    if score != nil {
                        CountUpNumber(value: shown, font: StrandFont.rounded(26))
                    } else {
                        Text("–").font(StrandFont.rounded(26))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsHitTesting(false)   // taps fall through to the vessel → splash
            }
            Button(action: onGuide) {
                HStack(spacing: 3) {
                    Text(label.uppercased()).font(StrandFont.overline).tracking(1.6)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                }
                // The hero card fill is pinned dark in BOTH themes, so the CHARGE/EFFORT/REST label must use
                // the scheme-invariant on-dark token — textSecondary flips to dark ink in Light mode and
                // went dark-on-near-black here (#1013).
                .foregroundStyle(StrandPalette.onDarkSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(label), \(score.map { String(Int($0.rounded())) } ?? String(localized: "no data yet")). See how it is scored."))
            if let pill {
                Text(pill)
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    // WHOOP pill on the pinned-dark hero card → on-dark token, not the theme-flipping one (#1013).
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(0.05))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)))
            } else {
                Color.clear.frame(height: 18) // keep the three labels vertically aligned
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { rollTo(score) }
        .onChangeCompat(of: score) { v in rollTo(v) }
    }

    private func rollTo(_ v: Double?) {
        guard let v else { shown = 0; return }
        withAnimation(.easeOut(duration: 0.9)) { shown = v }   // counts up in step with the vessel filling
    }
}


// MARK: - Scene controls (LiveState-isolated leaves)

/// Quick-actions "+" button. Tap → the shell's quick-action menu.
private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.requestQuickActions() } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Quick actions")
    }
}

/// The live heart-rate readout leaf. Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card,
/// never the whole Today (the isolation the classic Today depends on). Keeps its own rolling buffer of
/// live samples, shows the current bpm live with a beat-by-beat trace, and falls back to today's banked
/// 5-minute trace when the strap isn't streaming.
private struct LiquidLiveHR: View {
    var tint: Color
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    var animated: Bool

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    private var bigBpm: Int? {
        if let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: LocalizedStringKey {
        if isLive { return "Live · beat by beat" }
        if fallback.count >= 2 { return "5-minute average · since midnight" }
        return live.connected ? "Waiting for the strap" : "Strap not connected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEATS PER MINUTE").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                if isLive {
                    // A gentle heartbeat dot that pulses with each incoming sample.
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .scaleEffect(beat ? 1.35 : 0.85)
                        .opacity(beat ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.28), value: beat)
                        .padding(.trailing, 2)
                }
                if let hr = bigBpm {
                    (Text("\(hr)").font(StrandFont.rounded(22)).monospacedDigit()
                        + Text(" bpm").font(StrandFont.caption))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: hr)
                }
            }
            if series.count >= 2 {
                LiquidThread(bpm: series, tint: tint, height: 92, animated: animated)
                HStack {
                    stat("Min", series.min())
                    Spacer()
                    stat("Avg", series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat("Max", series.max())
                }
            } else {
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect your strap to see live heart rate")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private func stat(_ label: LocalizedStringKey, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Strap-battery ring. Owns LiveState. Tap → Devices.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.openDevices() } label: {
            ZStack {
                Circle().fill(Color(.sRGB, red: 10 / 255, green: 11 / 255, blue: 16 / 255, opacity: 0.5))
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                if let pct = live.batteryPct {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, pct / 100)))
                        .stroke(ringColor(pct), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2.5)
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    if live.charging == true {
                        // #972: the default Today never surfaced charging state — only the % ring. A small
                        // bolt over the ring gives the same signal as the "· Charging" text on Mac/Android.
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .offset(y: -10)
                    }
                } else {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(batteryAccessibility)
    }
    private var batteryAccessibility: String {
        let base = live.batteryPct.map { "Strap battery \(Int($0.rounded())) percent" } ?? "Strap battery"
        return live.charging == true ? base + ", charging" : base
    }
    private func ringColor(_ p: Double) -> Color {
        p < 15 ? StrandPalette.statusCritical : p < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }
}

/// The strap-battery readout inside the Data Sources card. Owns LiveState; display-only.
private struct LiquidStrapBatteryRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.connected, let pct = live.batteryPct {
            HStack {
                Text("Strap battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // #972: append "· Charging"; #992: append the "~X days left" runtime the v8 redesign dropped.
                Text(batteryText(pct: pct))
                    .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · " + String(localized: "Charging") }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: the v8 Liquid redesign dropped the "~X days left" estimate the classic Today showed (#713).
    /// Reproduced verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more round to
    /// days; nil (no banked discharge yet, or charging) hides it, so the row only ever shows an estimate we trust.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }
}

// MARK: - Today blocks: small pieces

/// A compact capsule action in the Today blocks (log a WOD, rename, start a session).
private struct ActionChip: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// The CGM-style trend arrow: flat, 45° or straight, doubled when fast.
private struct GlucoseTrendArrow: View {
    let trend: GlucoseNow.Trend

    var body: some View {
        HStack(spacing: -6) {
            ForEach(0..<(fast ? 2 : 1), id: \.self) { _ in Image(systemName: symbol) }
        }
        .font(.system(size: 24, weight: .bold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var fast: Bool { trend == .risingFast || trend == .fallingFast }

    private var symbol: String {
        switch trend {
        case .risingFast, .rising: return "arrow.up"
        case .risingSlowly: return "arrow.up.right"
        case .steady: return "arrow.right"
        case .fallingSlowly: return "arrow.down.right"
        case .falling, .fallingFast: return "arrow.down"
        }
    }

    private var label: Text {
        switch trend {
        case .risingFast: return Text("Rising fast")
        case .rising: return Text("Rising")
        case .risingSlowly: return Text("Rising slowly")
        case .steady: return Text("Steady")
        case .fallingSlowly: return Text("Falling slowly")
        case .falling: return Text("Falling")
        case .fallingFast: return Text("Falling fast")
        }
    }
}

/// Glucose over a window as a small chart: the 70–180 mg/dL target band, the line broken at sensor gaps, the
/// 70 mg/dL line, and the latest reading as a dot. Same colours as the Heart & Glucose timeline. Equatable,
/// so it redraws only when its readings change.
private struct GlucoseSparkline: View, Equatable {
    let points: [GlucoseTrace.Point]
    let window: ClosedRange<Double>

    nonisolated static func == (a: GlucoseSparkline, b: GlucoseSparkline) -> Bool {
        a.points == b.points && a.window == b.window
    }

    var body: some View {
        let lowest = points.map(\.mgdl).min() ?? 70
        let highest = points.map(\.mgdl).max() ?? 180
        let lo = max(0, (min(55, lowest - 8) / 10).rounded(.down) * 10)
        let hi = (max(200, highest + 12) / 20).rounded(.up) * 20
        Canvas { ctx, size in
            // A gutter on the left for the band's edge labels, so the line never runs through them.
            let gutter: CGFloat = 24
            let plotWidth = max(1, size.width - gutter)
            let span = max(1, window.upperBound - window.lowerBound)
            func x(_ ts: Double) -> CGFloat { gutter + CGFloat((ts - window.lowerBound) / span) * plotWidth }
            func y(_ v: Double) -> CGFloat { CGFloat(1 - (v - lo) / (hi - lo)) * size.height }
            // Target band, the low line and their labels.
            ctx.fill(Path(CGRect(x: gutter, y: y(180), width: plotWidth, height: y(70) - y(180))),
                     with: .color(StrandPalette.statusPositive.opacity(0.10)))
            var lowLine = Path()
            lowLine.move(to: CGPoint(x: gutter, y: y(70)))
            lowLine.addLine(to: CGPoint(x: size.width, y: y(70)))
            ctx.stroke(lowLine, with: .color(StrandPalette.statusCritical.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for v in [180.0, 70.0] {
                ctx.draw(Text(verbatim: "\(Int(v))").font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(StrandPalette.textTertiary),
                         at: CGPoint(x: 0, y: y(v)), anchor: .leading)
            }
            // The trace, one path per segment (no line across a sensor gap).
            var path = Path()
            var segment = -1
            for p in points {
                let pt = CGPoint(x: x(p.ts), y: y(p.mgdl))
                if p.segment != segment { path.move(to: pt); segment = p.segment } else { path.addLine(to: pt) }
            }
            var clipped = ctx
            clipped.clip(to: Path(CGRect(x: gutter, y: 0, width: plotWidth, height: size.height)))
            clipped.stroke(path, with: .color(StrandPalette.chartGlucose),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            // The latest reading, ringed in the card's surface so it reads over the line.
            if let last = points.last(where: { window.contains($0.ts) }) {
                let r: CGFloat = 4
                let dot = CGRect(x: x(last.ts) - r, y: y(last.mgdl) - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(StrandPalette.surfaceRaised))
                ctx.fill(Path(ellipseIn: dot),
                         with: .color(last.mgdl < GlucoseTrace.lowThreshold ? StrandPalette.statusCritical : StrandPalette.chartGlucose))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Glucose chart"))
        .accessibilityValue(Text("Lowest \(Int(lowest.rounded())), highest \(Int(highest.rounded())) mg/dL"))
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done).foregroundStyle(StrandPalette.accent)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).foregroundStyle(StrandPalette.accent)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
