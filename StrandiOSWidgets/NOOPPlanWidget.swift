import WidgetKit
import SwiftUI
import StrandDesign

/// "Today's plan" widget: the training word, why, tonight's bedtime and what to work on, next to the
/// Charge / Effort / Rest scores. The plan is judged against the entry date: a plan stored for another day
/// is treated as absent. General estimates, not medical advice.
struct NOOPPlanWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }
    private var plan: WidgetPlan? { WidgetPlan(snap, at: entry.date) }

    var body: some View {
        switch family {
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
                    Image(systemName: plan.symbol)
                    Text(verbatim: plan.word)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .widgetAccentable()
                }
                if let bed = plan.shortBedLine {
                    Text(verbatim: bed).font(.caption)
                }
                if let reason = plan.reasonText {
                    Text(verbatim: reason).font(.caption2).lineLimit(1)
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

    private var chargeRing: some View {
        ScoreRing(value: snap.recovery, tint: WidgetColors.charge(snap.recovery),
                  size: ringSize, lineWidth: ringSize > 50 ? 7 : 5, valueSize: ringValueSize)
    }

    private var ringSize: CGFloat {
        family == .systemSmall ? 44 : 64
    }

    private var ringValueSize: CGFloat {
        family == .systemSmall ? WidgetSize.mid : WidgetSize.big
    }

    private var effortCell: some View {
        StatCell(label: "Effort", value: snap.effort.map { $0.formatted() }, tint: WidgetColors.effort(snap.effort))
    }

    private var restCell: some View {
        StatCell(label: "Rest", value: widgetPercent(snap.rest), tint: WidgetColors.rest(snap.rest))
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

    /// The training word and its reason; `details` adds the bedtime and the first focus (medium).
    private func planColumn(_ plan: WidgetPlan, details: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PlanWord(plan: plan, size: WidgetSize.big)
            if let reason = plan.reasonText {
                CaptionText(text: reason, lines: 1)
            }
            if details {
                if let sleep = plan.sleepLine {
                    Text(verbatim: sleep)
                        .font(.system(size: WidgetSize.mid, weight: .semibold, design: .rounded))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .minimumScaleFactor(0.8)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
                if let focus = plan.focusText {
                    CaptionText(text: focus, lines: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyMessage: some View {
        Text("Open NOOP to build today's plan")
            .font(.system(size: WidgetSize.caption, weight: .medium))
            .foregroundStyle(StrandPalette.textSecondary)
    }

    // MARK: - Home Screen

    @ViewBuilder private var small: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 6) {
                PlanWord(plan: plan, size: WidgetSize.big)
                if let reason = plan.reasonText {
                    CaptionText(text: reason, lines: 2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    chargeRing
                    Text("Charge")
                        .font(.system(size: WidgetSize.caption, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    scores
                    planColumn(plan, details: false)
                }
                Divider()
                sleepBlock(plan)
                nutritionRow(plan)
                Spacer(minLength: 0)
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

    private func sleepBlock(_ plan: WidgetPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sleep = plan.sleepLine {
                Text(verbatim: sleep)
                    .font(.system(size: WidgetSize.mid, weight: .semibold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            if let target = plan.sleepTargetLine {
                CaptionText(text: target, lines: 1)
            }
            if let focus = plan.focusText {
                CaptionText(text: focus, lines: 2)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func nutritionRow(_ plan: WidgetPlan) -> some View {
        if plan.energy != nil || plan.protein != nil || plan.carbs != nil {
            HStack(spacing: 8) {
                StatCell(label: "Energy (kcal)", value: plan.energy.map(WidgetPlan.rangeText))
                StatCell(label: "Protein (g)", value: plan.protein.map(WidgetPlan.rangeText))
                StatCell(label: "Carbs (g)", value: plan.carbs.map(WidgetPlan.rangeText))
            }
        }
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
            .accessoryRectangular, .accessoryInline
        ])
    }
}
