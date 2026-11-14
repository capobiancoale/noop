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
    let hasGlucose: Bool
    let askCoach: () -> Void

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
        switch plan.training {
        case .push: return String(localized: "Go for a hard session")
        case .maintain: return String(localized: "Train at normal intensity")
        case .easy: return String(localized: "Keep it light or rest")
        }
    }

    private var trainingRow: some View {
        actionRow(symbol: "figure.strengthtraining.traditional", tint: trainingTint) {
            actionHeadline(trainingHeadline)
            bodyLine(reasonsLine)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(localized: "Training: \(trainingWord). \(reasonsLine)")))
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

    private var sleepDetail: String? {
        plan.sleep.bedtimeMinutes == nil ? nil : String(localized: "Target \(Self.duration(plan.sleep.minutes))")
    }

    private var sleepRow: some View {
        actionRow(symbol: "moon.fill", tint: StrandPalette.restColor) {
            actionHeadline(sleepHeadline)
            if let sleepDetail { bodyLine(sleepDetail) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [tonightLine, bedtimeLine].compactMap { $0 }.joined(separator: ", ")))
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
