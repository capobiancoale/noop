import WidgetKit
import SwiftUI
import StrandDesign

/// "Today's plan" widget: the training word (or "Rest day"), why, the session and meal time, tonight's bedtime
/// and what to work on, next to the Charge / Effort / Rest scores. The plan is judged against the entry date:
/// a plan stored for another day is treated as absent. General estimates, not medical advice.
///
/// Sizes: hero word `WidgetSize.big`, figures and the large rows `WidgetSize.mid`, everything else
/// `WidgetSize.caption`. One Charge ring size per family (`ringSize`).
struct NOOPPlanWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: NOOPEntry
    /// Set only by the debug widget gallery, which cannot write `widgetFamily` (it is read-only).
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    init(entry: NOOPEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var snap: WidgetSnapshot { entry.snapshot }
    private var plan: WidgetPlan? { WidgetPlan(snap, at: entry.date) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        case .systemLarge:
            large
        default:
            small
        }
    }

    // MARK: - Lock Screen

    /// The Charge ring as a gauge with the level's glyph inside; the Charge number when there is no plan.
    private var circular: some View {
        Gauge(value: Double(min(max(snap.recovery ?? 0, 0), 100)), in: 0...100) {
            Text("Charge")
        } currentValueLabel: {
            if let plan {
                Image(systemName: plan.circularSymbol)
            } else {
                Text(verbatim: snap.recovery.map { $0.formatted() } ?? "–")
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(WidgetColors.charge(snap.recovery))
    }

    @ViewBuilder private var inline: some View {
        if let plan {
            Text(verbatim: plan.inlineText)
        } else {
            Text(verbatim: "NOOP")
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: plan.headlineSymbol)
                    Text(verbatim: plan.headlineWord)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .widgetAccentable()
                }
                ForEach(plan.lockLines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "NOOP").font(.headline)
                Text("Open NOOP to build today's plan").font(.caption)
            }
        }
    }

    // MARK: - Pieces

    /// One ring size per family: 52 small, 76 medium and large.
    private var ringSize: CGFloat {
        family == .systemSmall ? 52 : 76
    }

    private var chargeRing: some View {
        ScoreRing(value: snap.recovery, tint: WidgetColors.charge(snap.recovery),
                  size: ringSize, lineWidth: family == .systemSmall ? 6 : 8,
                  valueSize: family == .systemSmall ? WidgetSize.mid : WidgetSize.big)
    }

    private var effortCell: some View {
        StatCell(label: "Effort", value: snap.effort.map { $0.formatted() }, tint: WidgetColors.effort(snap.effort))
    }

    private var restCell: some View {
        StatCell(label: "Rest", value: snap.rest.map { $0.formatted() }, tint: WidgetColors.rest(snap.rest))
    }

    /// Charge ring with Effort and Rest beside it.
    private var scores: some View {
        HStack(spacing: 10) {
            chargeRing
            VStack(alignment: .leading, spacing: 10) {
                effortCell
                restCell
            }
        }
        .fixedSize()
    }

    private var emptyMessage: some View {
        Text("Open NOOP to build today's plan")
            .font(.system(size: WidgetSize.caption, weight: .medium))
            .foregroundStyle(StrandPalette.textSecondary)
    }

    /// Caption-size row text in the primary colour (medium rows).
    private func rowCaption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: WidgetSize.caption, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Mid-size row text in the primary colour (large rows).
    private func rowMid(_ text: String, weight: Font.Weight = .semibold, lines: Int = 2) -> some View {
        Text(verbatim: text)
            .font(.system(size: WidgetSize.mid, weight: weight, design: .rounded))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(lines)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The headline and what sits under it. Medium (`details`) adds the session and bedtime rows; large shows
    /// them in the block below instead.
    private func planColumn(_ plan: WidgetPlan, details: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PlanWord(plan: plan, size: WidgetSize.big)
            if let note = plan.ifYouTrainLine {
                CaptionText(text: note, lines: 1)
            }
            if let reason = plan.reasonText, !(details && plan.restDay) {
                CaptionText(text: reason, lines: 1)
            }
            if details {
                VStack(alignment: .leading, spacing: 6) {
                    if let session = plan.sessionLine {
                        WidgetIconRow(symbol: "figure.strengthtraining.traditional", tint: plan.headlineTint, tile: 22) {
                            rowCaption(session)
                        }
                    }
                    if let sleep = plan.sleepLine {
                        WidgetIconRow(symbol: "moon.fill", tint: StrandPalette.restColor, tile: 22) {
                            rowCaption(sleep)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Home Screen

    /// Small: the hero word on top (it also carries StandBy, where this size is shown large), the Charge ring
    /// and the one-line note below.
    @ViewBuilder private var small: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 6) {
                PlanWord(plan: plan, size: WidgetSize.big, lines: 2)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    chargeRing
                    if let note = plan.subLine {
                        CaptionText(text: note, lines: 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                chargeRing
                emptyMessage
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var medium: some View {
        if let plan {
            HStack(spacing: 16) {
                scores
                planColumn(plan, details: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 16) {
                scores
                emptyMessage.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var large: some View {
        if let plan {
            // The blocks share the height evenly: fixed spacing left the lower half of the widget empty.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    scores
                    planColumn(plan, details: false)
                }
                Spacer(minLength: 8)
                Divider()
                Spacer(minLength: 8)
                rows(plan)
                Spacer(minLength: 8)
                nutritionRow(plan)
                Spacer(minLength: 8)
                footer
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    scores
                    emptyMessage.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                footer
            }
        }
    }

    // MARK: - Large pieces

    /// Session and meal time, tonight's bedtime and the first thing to work on, each beside a tinted symbol.
    private func rows(_ plan: WidgetPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = plan.sessionLine {
                WidgetIconRow(symbol: "figure.strengthtraining.traditional", tint: plan.headlineTint) {
                    rowMid(session)
                }
            }
            if let sleep = plan.sleepLine {
                WidgetIconRow(symbol: "moon.fill", tint: StrandPalette.restColor) {
                    rowMid(sleep, lines: 1)
                    if let target = plan.sleepTargetLine {
                        CaptionText(text: target, lines: 1)
                    }
                }
            }
            if let focus = plan.focusText {
                WidgetIconRow(symbol: "scope", tint: StrandPalette.statusWarning) {
                    rowMid(focus, weight: .medium)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func nutritionRow(_ plan: WidgetPlan) -> some View {
        if plan.energy != nil || plan.protein != nil || plan.carbs != nil {
            HStack(spacing: 8) {
                nutritionTile(StatCell(label: "Energy (kcal)", value: plan.energy.map(WidgetPlan.rangeText)))
                nutritionTile(StatCell(label: "Protein (g)", value: plan.protein.map(WidgetPlan.rangeText)))
                nutritionTile(StatCell(label: "Carbs (g)", value: plan.carbs.map(WidgetPlan.rangeText)))
            }
        }
    }

    private func nutritionTile(_ cell: StatCell) -> some View {
        cell
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let battery = widgetPercent(snap.batteryPct) {
                Label(battery, systemImage: "battery.50")
            }
            Spacer(minLength: 0)
            Text(verbatim: String(localized: "Updated \(snap.updated.formatted(date: .omitted, time: .shortened))"))
        }
        .font(.system(size: WidgetSize.caption, weight: .medium))
        .foregroundStyle(StrandPalette.textTertiary)
    }
}

struct NOOPPlanWidget: Widget {
    let kind = "NOOPPlanWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPPlanWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Today's plan")
        .description("Today's training advice, tonight's bedtime and what to work on, next to Charge, Effort and Rest.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular
        ])
    }
}
