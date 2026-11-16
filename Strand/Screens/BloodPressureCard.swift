import SwiftUI
import Foundation
import StrandDesign
import StrandImport

// MARK: - Blood pressure card (metric detail for bp_systolic / bp_diastolic)
//
// Shows the MEASURED blood pressure NOOP has: the latest day with both a systolic and a diastolic value
// ("128/82 mmHg"), its ESH 2023 category word (StrandImport.BloodPressure, Mancia et al., J Hypertens
// 2023), the 30-day averages, and a button that opens the Lab Book entry for blood pressure. The values
// come from a cuff that writes to Apple Health and from readings typed here, merged to one value per day
// (Repository+Vitals). NOOP does not estimate blood pressure: a cuffless estimate from a wrist optical
// sensor is not validated without a cuff calibration (Stergiou et al., J Hypertens 2022; ISO 81060-3:2022).
//
// Informational only, not medical advice. One day's mean, or an average across different conditions, is
// not a diagnosis; the category word names where the number falls in the guideline's table, nothing more.

struct BloodPressureCard: View {
    @EnvironmentObject var repo: Repository

    /// Called after a reading is saved, so the host (the metric detail) re-reads its chart.
    var onSaved: () async -> Void = {}

    @State private var summary: BloodPressure.Summary?
    @State private var loaded = false
    @State private var showingEditor = false

    var body: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Blood pressure").strandOverline()
                if let summary {
                    latestBlock(summary)
                    averagesBlock(summary)
                } else if loaded {
                    Text("No blood pressure reading yet. A reading needs both the top (systolic) and bottom (diastolic) number.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    showingEditor = true
                } label: {
                    Label("Add a reading", systemImage: "plus")
                }
                .buttonStyle(.noopPrimary)
                Text("NOOP shows measured blood pressure only: from a cuff that writes to Apple Health, or readings you add here. A wrist strap can't measure blood pressure reliably without a cuff, so NOOP doesn't estimate it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Informational only, not medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $showingEditor) {
            MarkerEditorView(initialMarkerKey: BloodPressure.systolicKey) { drafts in
                await repo.addLabMarkers(drafts)
                await load()
                await onSaved()
            }
        }
    }

    // MARK: Pieces

    private func latestBlock(_ s: BloodPressure.Summary) -> some View {
        let reading = Self.format(systolic: s.latest.systolic, diastolic: s.latest.diastolic)
        let asOf = String(localized: "as of \(LabBookFormat.dayFromKey(s.latest.day))")
        return VStack(alignment: .leading, spacing: 4) {
            Text("Latest").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: reading)
                .font(StrandFont.number(34))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                if let category = s.latest.category {
                    Text(Self.title(category))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(StrandPalette.surfaceInset, in: Capsule())
                }
                Text(asOf).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func averagesBlock(_ s: BloodPressure.Summary) -> some View {
        if let sys = s.avgSystolic, let dia = s.avgDiastolic {
            let average = Self.format(systolic: sys, diastolic: dia)
            VStack(alignment: .leading, spacing: 4) {
                Text("30-day average").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: average)
                    .font(StrandFont.number(22))
                    .foregroundStyle(StrandPalette.textPrimary)
                // Whole-phrase variants per count so translators never see a stitched plural.
                Text(s.daysInWindow == 1
                     ? String(localized: "1 day with a reading")
                     : String(localized: "\(s.daysInWindow) days with a reading"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("No readings in the last 30 days.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Load

    private func load() async {
        summary = await repo.bloodPressureOverview()
        loaded = true
    }

    // MARK: Formatting

    /// "128/82 mmHg": whole mmHg, as cuffs report it (and as `BloodPressure.classify` reads it).
    static func format(systolic: Double, diastolic: Double) -> String {
        "\(Int(systolic.rounded()))/\(Int(diastolic.rounded())) mmHg"
    }

    /// The ESH 2023 category as a word, localized.
    static func title(_ category: BloodPressure.Category) -> String {
        switch category {
        case .optimal:          return String(localized: "Optimal")
        case .normal:           return String(localized: "Normal")
        case .highNormal:       return String(localized: "High-normal")
        case .grade1:           return String(localized: "Grade 1 hypertension")
        case .grade2:           return String(localized: "Grade 2 hypertension")
        case .grade3:           return String(localized: "Grade 3 hypertension")
        case .isolatedSystolic: return String(localized: "Isolated systolic hypertension")
        }
    }
}
