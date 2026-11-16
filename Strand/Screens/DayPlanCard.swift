import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Today's plan
//
// One compact card: how hard to train, how long to sleep tonight, rough energy / protein / carbohydrate /
// fluid ranges and up to three things to work on. All numbers come from `DayPlan` (pure engine, keys and
// numbers only); this view builds the localized words. General sports-science estimates, not medical advice.
// Insulin is never calculated here: the card only says so when a glucose source is connected.

struct DayPlanCard: View {
    let snapshot: DayPlanBuilder.Snapshot
    @Binding var goal: String
    /// The wake-up time the user wants (minutes after local midnight), -1 = automatic.
    @Binding var wakeMinutes: Int
    let hasGlucose: Bool
    let askCoach: () -> Void

    @State private var showWakeSheet = false

    private var plan: DayPlan.Plan { snapshot.plan }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                trainingRow
                nutritionRow
                sleepRow
                focusBlock
                NoopButton("Ask the Coach", systemImage: "bubble.left.and.text.bubble.right",
                           kind: .secondary, fullWidth: true, action: askCoach)
            }
        }
        .sheet(isPresented: $showWakeSheet) {
            WakeTimeSheet(minutes: $wakeMinutes, suggested: plan.sleep.wakeMinutes)
        }
    }

    // MARK: - Header and goal chip

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Today's plan")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            goalMenu
        }
    }

    private var goalMenu: some View {
        Menu {
            Picker("Goal", selection: $goal) {
                Text("Performance").tag("performance")
                Text("Strength and muscle").tag("strength")
                Text("Lose fat").tag("fatLoss")
                Text("Endurance").tag("endurance")
                Text("General health").tag("health")
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: Self.goalName(goal))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(StrandFont.footnote.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(StrandPalette.accent.opacity(0.14), in: Capsule(style: .continuous))
        }
        .accessibilityLabel(Text(verbatim: String(localized: "Goal: \(Self.goalName(goal))")))
    }

    static func goalName(_ raw: String) -> String {
        switch DayPlanBuilder.goal(from: raw) {
        case .performance: return String(localized: "Performance")
        case .strength: return String(localized: "Strength and muscle")
        case .fatLoss: return String(localized: "Lose fat")
        case .endurance: return String(localized: "Endurance")
        case .health: return String(localized: "General health")
        }
    }

    // MARK: - Rows

    private func rowTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(StrandFont.overline)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textTertiary)
    }

    private func bodyLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Training

    private var trainingWord: String {
        switch plan.training {
        case .push: return String(localized: "Push")
        case .maintain: return String(localized: "Maintain")
        case .easy: return String(localized: "Easy day")
        }
    }

    private var trainingTint: Color {
        if plan.isRestDay { return StrandPalette.textSecondary }
        switch plan.training {
        case .push: return StrandPalette.statusPositive
        case .maintain: return StrandPalette.statusWarning
        case .easy: return StrandPalette.textSecondary
        }
    }

    private var reasonsLine: String {
        plan.reasons.map(Self.reasonText).joined(separator: " · ")
    }

    /// What to do, as a sentence: the hero's verdict chip already carries the one-word level.
    private var trainingHeadline: String {
        if plan.isRestDay { return String(localized: "Rest day by your schedule") }
        switch plan.training {
        case .push: return String(localized: "Go for a hard session")
        case .maintain: return String(localized: "Train at normal intensity")
        case .easy: return String(localized: "Keep it light or rest")
        }
    }

    /// On a rest day by schedule the level is still computed, but it reads as what the data would allow.
    private var restDayLine: String? {
        plan.isRestDay ? String(localized: "If you train anyway: \(trainingWord.lowercased())") : nil
    }

    /// "Session at 19:00: eat your main meal by 16:00–16:30" (about 3 h before; general sports-nutrition guidance).
    private var preSessionLine: String? {
        guard let pre = plan.preSession else { return nil }
        return String(localized: "Session at \(Self.clock(pre.startMinutes)): eat your main meal by \(Self.clock(pre.mealFromMinutes))–\(Self.clock(pre.mealToMinutes))")
    }

    /// "Your thresholds, from 64 days" or "Standard thresholds: yours in about 12 days"; nil when the plan was
    /// made without thresholds input.
    private var thresholdsLine: String? {
        guard let t = plan.thresholds else { return nil }
        if t.isPersonal { return String(localized: "Your thresholds, from \(t.chargeDays) days") }
        return String(localized: "Standard thresholds: yours in about \(t.daysUntilPersonal) days")
    }

    private var trainingRow: some View {
        actionRow(symbol: "figure.strengthtraining.traditional", tint: trainingTint) {
            actionHeadline(trainingHeadline)
            if let restDayLine { bodyLine(restDayLine) }
            bodyLine(reasonsLine)
            if let thresholdsLine {
                Text(verbatim: thresholdsLine)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preSessionLine {
                bodyLine(preSessionLine).padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: trainingAccessibility))
    }

    private var trainingAccessibility: String {
        var parts: [String] = []
        if plan.isRestDay { parts.append(trainingHeadline) }
        if let restDayLine { parts.append(restDayLine) }
        parts.append(String(localized: "Training: \(trainingWord). \(reasonsLine)"))
        if let thresholdsLine { parts.append(thresholdsLine) }
        if let preSessionLine { parts.append(preSessionLine) }
        return parts.joined(separator: ". ")
    }

    /// One step of the day: a tinted symbol tile on the left, the action and its detail on the right.
    private func actionRow<Content: View>(symbol: String, tint: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionHeadline(_ text: String) -> some View {
        Text(verbatim: text)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func reasonText(_ reason: DayPlan.Reason) -> String {
        switch reason {
        case .chargeHigh(let n), .chargeMid(let n), .chargeLow(let n):
            return String(localized: "Charge \(n)")
        case .noCharge:
            return String(localized: "No Charge yet")
        case .shortSleep(let minutes, _):
            return String(localized: "short night \(Self.duration(minutes))")
        case .loadSharpRise(let ratio):
            return String(localized: "load \(DisplayNumber.decimal(ratio, digits: 1))× your usual")
        case .hardStreak(let days):
            return String(localized: "\(days) hard days in a row")
        }
    }

    // Sleep

    private var tonightLine: String {
        String(localized: "Tonight: \(Self.duration(plan.sleep.minutes))")
    }

    private var bedtimeLine: String? {
        guard let bed = plan.sleep.bedtimeMinutes else { return nil }
        let cal = Calendar.current
        let date = cal.date(bySettingHour: bed / 60, minute: bed % 60, second: 0, of: Date()) ?? Date()
        let clock = date.formatted(date: .omitted, time: .shortened)
        return String(localized: "in bed by \(clock)")
    }

    /// "In bed by 22:30" when the usual wake time is known, else the night's target as the action.
    private var sleepHeadline: String {
        if let bed = plan.sleep.bedtimeMinutes {
            let cal = Calendar.current
            let date = cal.date(bySettingHour: bed / 60, minute: bed % 60, second: 0, of: Date()) ?? Date()
            return String(localized: "In bed by \(date.formatted(date: .omitted, time: .shortened))")
        }
        return String(localized: "Sleep \(Self.duration(plan.sleep.minutes)) tonight")
    }

    /// "Wake-up 07:00 · target 8 h 20 min"; without a known wake time, an invitation to set one.
    private var sleepDetail: String? {
        guard plan.sleep.bedtimeMinutes != nil, let wake = plan.sleep.wakeMinutes else {
            return String(localized: "Tap to set your wake-up time")
        }
        return String(localized: "Wake-up \(Self.clock(wake)) · target \(Self.duration(plan.sleep.minutes))")
    }

    /// "Includes 30 min more: you train tomorrow and today's Charge is below your usual".
    private var sleepReasonLines: [String] {
        plan.sleep.reasons.map { reason in
            switch reason {
            case .trainingTomorrow(let added):
                return String(localized: "Includes \(added) min more: you train tomorrow and today's Charge is below your usual")
            }
        }
    }

    private var sleepRow: some View {
        Button { showWakeSheet = true } label: {
            HStack(alignment: .center, spacing: 8) {
                actionRow(symbol: "moon.fill", tint: StrandPalette.restColor) {
                    actionHeadline(sleepHeadline)
                    if let sleepDetail { bodyLine(sleepDetail) }
                    ForEach(Array(sleepReasonLines.enumerated()), id: \.offset) { _, line in bodyLine(line) }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([tonightLine, bedtimeLine, sleepDetail].compactMap { $0 } + sleepReasonLines).joined(separator: ", ")))
        .accessibilityHint(Text("Opens the wake-up time setting"))
        .accessibilityAddTraits(.isButton)
    }

    // Nutrition

    private var nutritionRow: some View {
        actionRow(symbol: "fork.knife", tint: StrandPalette.statusPositive) {
            actionHeadline(String(localized: "Eat to match the day"))
            if let n = plan.nutrition {
                nutritionFigures(n).padding(.top, 4)
                nutritionCaptions.padding(.top, 2)
            } else {
                bodyLine(String(localized: "Add your age, weight and height in the profile to see this."))
            }
        }
    }

    private func nutritionFigures(_ n: DayPlan.Nutrition) -> some View {
        let energy = String(localized: "\(Self.whole(n.energyKcal.lowerBound))–\(Self.whole(n.energyKcal.upperBound)) kcal")
        let protein = String(localized: "\(Self.whole(n.proteinG.lowerBound))–\(Self.whole(n.proteinG.upperBound)) g")
        let carbs = String(localized: "\(Self.whole(n.carbsG.lowerBound))–\(Self.whole(n.carbsG.upperBound)) g")
        let fluids = String(localized: "\(DisplayNumber.decimal(Double(n.fluidMl) / 1000, digits: 1)) L")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                figure("Energy", energy)
                figure("Protein", protein)
            }
            HStack(alignment: .top, spacing: 8) {
                figure("Carbs", carbs)
                figure("Fluids", fluids)
            }
        }
    }

    private func figure(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var nutritionCaptions: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Estimates from your profile and today's plan. Not medical advice.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if hasGlucose {
                Text("NOOP never calculates insulin: dosing stays with you, your care team and Loop.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Focus

    @ViewBuilder private var focusBlock: some View {
        let items = Array(plan.focus.prefix(3))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                rowTitle("Work on")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    focusLine(Self.focusText(item))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func focusLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    static func focusText(_ focus: DayPlan.Focus) -> String {
        switch focus {
        case .sleepDebt(let minutes):
            return String(localized: "Sleep debt \(Self.duration(minutes)): tonight's target includes an extra hour")
        case .lowSleepAverage(let avg, let need):
            return String(localized: "Sleep averages \(Self.duration(avg)) a night against \(Self.duration(need)) needed")
        case .irregularWake(let sd):
            return String(localized: "Wake time varies by about \(sd) min: keep it steady")
        case .loadHigh(let ratio):
            return String(localized: "Training load is \(DisplayNumber.decimal(ratio, digits: 1))× your usual: keep some days easy")
        case .loadLow(let ratio):
            return String(localized: "Training load is \(DisplayNumber.decimal(ratio, digits: 1))× your usual: there is room to do more")
        case .hrvDown(let pct, let recent, let usual):
            return String(localized: "HRV is \(pct)% below your usual (\(DisplayNumber.decimal(recent, digits: 0)) against \(DisplayNumber.decimal(usual, digits: 0)) ms)")
        case .restingHrUp(let bpm, let recent, let usual):
            return String(localized: "Resting heart rate is \(DisplayNumber.decimal(bpm, digits: 0)) bpm above your usual (\(DisplayNumber.decimal(recent, digits: 0)) against \(DisplayNumber.decimal(usual, digits: 0)))")
        }
    }

    // MARK: - Formatting

    /// "5 h 30 min" / "45 min" / "8 h", the same wording the heart-rhythm card uses.
    static func duration(_ minutes: Int) -> String {
        HeartRhythmCard.durationText(minutes: Double(minutes))
    }

    /// A time of day (minutes after local midnight) in the phone's clock style.
    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let date = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// A whole number in the user's locale ("2.450" / "2,450" / "2450").
    private static func whole(_ v: Int) -> String {
        v.formatted(.number.grouping(.never))
    }
}

/// "Ask the Coach" from the plan card: NavRouter has no Coach destination, so the Coach opens in a sheet.
struct DayPlanCoachSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CoachView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }
}

// MARK: - Wake-up time

/// The wake-up time as a control: an "Automatic" switch and, when it is off, a time picker. Shared by the
/// plan card's sheet and the Settings profile section. `minutes` is minutes after local midnight, -1 = automatic.
struct WakeTimeField: View {
    @Binding var minutes: Int
    /// The time the picker starts at when the user turns Automatic off.
    var suggested: Int?
    var autoLabel: LocalizedStringKey = "Automatic (from my usual wake time)"

    private var automatic: Binding<Bool> {
        Binding(
            get: { minutes < 0 },
            set: { on in minutes = on ? -1 : (suggested ?? 7 * 60) })
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                let m = minutes < 0 ? (suggested ?? 7 * 60) : minutes
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Toggle(autoLabel, isOn: automatic)
            if minutes >= 0 {
                DatePicker("Wake-up time", selection: time, displayedComponents: .hourAndMinute)
            }
        }
    }
}

/// Opened from the plan card's sleep row: set when you want to wake up. iPhone gives apps no access to the
/// Clock app's alarms, so the time is set here.
struct WakeTimeSheet: View {
    @Binding var minutes: Int
    var suggested: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WakeTimeField(minutes: $minutes, suggested: suggested)
                } footer: {
                    Text("iPhone does not let apps read the alarms in the Clock app, so you set your wake-up time here. When it is automatic and NOOP's smart alarm is on, the plan uses the alarm's time.")
                }
            }
            .navigationTitle(Text("Wake-up time"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}
