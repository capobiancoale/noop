import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest `WidgetSnapshot` the app published into the App Group.
struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Shared by the Charge widget and the plan widget.
struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        let snap = WidgetSnapshot.load() ?? .placeholder
        let now = Date()
        // Refresh roughly every 15 minutes; the app also forces a reload when it publishes fresh data.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        var entries = [NOOPEntry(date: now, snapshot: snap)]
        // A second entry at the next day rollover (04:00 local), so a stored plan is judged again then even if
        // the system delays the reload: yesterday's advice must not linger as today's.
        let rollover = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: WidgetSnapshot.planRolloverHour, minute: 0),
            matchingPolicy: .nextTime)
        if let rollover { entries.append(NOOPEntry(date: rollover, snapshot: snap)) }
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

/// The glanceable Charge widget: Charge ring, Effort, Rest, heart rate and strap battery. The large size
/// also carries today's training word when a plan for today is stored.
struct NOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            recoveryGauge
        case .accessoryInline:
            Text(verbatim: inlineText)
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

    private var inlineText: String {
        var parts: [String] = []
        if let r = snap.recovery { parts.append(String(localized: "Charge \(r.formatted())%")) }
        if let b = snap.bpm { parts.append(String(localized: "\(b.formatted()) bpm")) }
        return parts.isEmpty ? "NOOP" : parts.joined(separator: " · ")
    }

    private var recoveryGauge: some View {
        Gauge(value: Double(snap.recovery ?? 0), in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(verbatim: snap.recovery.map { $0.formatted() } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(WidgetColors.charge(snap.recovery))
    }

    /// Two lines: the Charge headline, then live HR next to Effort.
    private var rectangular: some View {
        let charge = snap.recovery.map { $0.formatted() } ?? "–"
        let hr = snap.bpm.map { $0.formatted() } ?? "–"
        let effort = snap.effort.map { $0.formatted() } ?? "–"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(WidgetColors.charge(snap.recovery))
                Text(verbatim: String(localized: "Charge \(charge)%"))
                    .font(.headline)
            }
            Text(verbatim: String(localized: "HR \(hr) · Effort \(effort)"))
                .font(.caption)
        }
    }

    // MARK: - Home Screen

    private var ring: some View {
        ScoreRing(value: snap.recovery, tint: WidgetColors.charge(snap.recovery),
                  size: ringSize, lineWidth: ringSize > 80 ? 9 : 7, valueSize: WidgetSize.big)
    }

    private var ringSize: CGFloat {
        switch family {
        case .systemLarge: return 96
        case .systemMedium: return 84
        default: return 62
        }
    }

    private var effortCell: some View {
        StatCell(label: "Effort", value: snap.effort.map { $0.formatted() }, tint: WidgetColors.effort(snap.effort))
    }

    private var restCell: some View {
        StatCell(label: "Rest", value: widgetPercent(snap.rest), tint: WidgetColors.rest(snap.rest))
    }

    private var hrCell: some View {
        StatCell(label: "HR", value: snap.bpm.map { String(localized: "\($0.formatted()) bpm") })
    }

    private var batteryCell: some View {
        StatCell(label: "Battery", value: widgetPercent(snap.batteryPct))
    }

    private var small: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Charge")
                    .font(.system(size: WidgetSize.caption, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                BondDot(bonded: snap.bonded)
            }
            ring.frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                effortCell
                restCell
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 20) {
            VStack(spacing: 6) {
                ring
                Text("Charge")
                    .font(.system(size: WidgetSize.caption, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) { effortCell; restCell }
                HStack(spacing: 8) { hrCell; batteryCell }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { BondDot(bonded: snap.bonded) }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                VStack(spacing: 6) {
                    ring
                    Text("Charge")
                        .font(.system(size: WidgetSize.caption, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    effortCell
                    restCell
                }
                BondDot(bonded: snap.bonded)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            Divider()
            HStack(spacing: 8) {
                StatCell(label: "HRV", value: snap.hrv.map { String(localized: "\($0.formatted()) ms") })
                StatCell(label: "Rest HR", value: snap.restingHr.map { String(localized: "\($0.formatted()) bpm") })
            }
            HStack(spacing: 8) { hrCell; batteryCell }
            Spacer(minLength: 0)
            if let plan = WidgetPlan(snap, at: entry.date) {
                planLine(plan)
            }
        }
    }

    /// Today's training word and its reason, at the foot of the large Charge widget.
    private func planLine(_ plan: WidgetPlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: plan.word)
                .font(.system(size: WidgetSize.mid, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetColors.training(plan.training))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .widgetAccentable()
            if let reason = plan.reasonText {
                CaptionText(text: reason, lines: 1)
            }
        }
    }
}

struct NOOPWidget: Widget {
    let kind = "NOOPWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Charge")
        .description("Charge, Effort, Rest, HRV, resting and live heart rate, and strap battery at a glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}
