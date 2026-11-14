import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Why there's no Charge yet
//
// Opened from the note under the Today scores while Charge is empty. Charge compares last night's HRV with the
// person's own baseline, and the HRV comes from the beat-to-beat intervals the strap delivers during sleep.
// Instead of a bare "appears once last night's sleep is in", this shows what last night actually recorded
// (hours of heart rate, beats, share of the night with beats) and, only where the numbers point at it, what to
// try. Nothing here is estimated: every figure is counted from the stored samples
// (Repository+RecoveryDiagnostics, StrandAnalytics.NightCoverage).

struct ChargeMissingSheet: View {
    let onClose: () -> Void

    @EnvironmentObject private var repo: Repository
    @State private var diag: Repository.RecoveryDiagnostics?

    var body: some View {
        VStack(spacing: 0) {
            SheetTitleBar(title: "Why there's no Charge yet", onClose: onClose)
            Divider().overlay(StrandPalette.hairline)
            ScreenScaffold(title: nil) {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    Text("Charge compares last night's heart-rate variability (HRV) with your own baseline. It needs the strap's beat-to-beat data from the night, and a few nights of it before your baseline exists.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let diag {
                        baselineCard(diag)
                        lastNightCard(diag)
                        fixesCard(diag.fixes)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Text("Informational only, not medical advice.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .task(id: repo.refreshSeq) { diag = await repo.recoveryDiagnostics() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 560)
        #endif
    }

    // MARK: Baseline

    private func baselineCard(_ d: Repository.RecoveryDiagnostics) -> some View {
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your baseline").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                fact("Nights with a usable HRV, last 7 days", Text(verbatim: "\(d.usableNightsLast7)"))
                fact("Nights needed to start Charge", Text(verbatim: "\(d.nightsNeeded)"))
                if d.usableNightsLast7 >= d.nightsNeeded {
                    Text("You have enough recent nights. Charge appears after the next analysis.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Last night

    @ViewBuilder
    private func lastNightCard(_ d: Repository.RecoveryDiagnostics) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last night").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if let c = d.coverage, let start = d.sleepStart, let end = d.sleepEnd {
                    fact("Sleep", Text(verbatim: sleepText(start: start, end: end)))
                    fact("Heart rate recorded", Text(verbatim: hoursText(c.hrHours)))
                    fact("Beat-to-beat intervals", Text("\(c.rrBeats) beats"))
                    fact("Night covered by beats", Text(verbatim: percentText(c.rrShare)))
                    fact("Usable 5-minute stretches", Text("\(c.usableWindows) of \(c.totalWindows)"))
                    verdictText(c.verdict)
                        .font(StrandFont.subhead)
                        .foregroundStyle(c.verdict == .enough ? StrandPalette.textSecondary : StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("NOOP didn't find a main sleep that ended in the last 18 hours, so there is nothing to measure yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func verdictText(_ verdict: NightCoverage.Verdict) -> Text {
        switch verdict {
        case .enough:
            return Text("Last night has enough beats to compute an HRV.")
        case .tooSparse:
            return Text("Some beats came through, but not enough clean stretches in a row to compute an HRV.")
        case .noBeatToBeat:
            return Text("Heart rate was recorded, but almost no beat-to-beat data came with it. HRV, and so Charge, needs those beats.")
        case .noHeartRate:
            return Text("The strap recorded very little of the night.")
        }
    }

    // MARK: What to try

    @ViewBuilder
    private func fixesCard(_ fixes: NightCoverage.Fixes) -> some View {
        if !fixes.isEmpty {
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What to try").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    if fixes.contains(.stayConnected) {
                        fixRow("antenna.radiowaves.left.and.right", stayConnectedText)
                    }
                    if fixes.contains(.chargeStrap) {
                        fixRow("bolt.fill", Text("Charge the strap so it can store the night."))
                    }
                    if fixes.contains(.wearSnug) {
                        fixRow("waveform.path.ecg",
                               Text("Wear the strap snugly overnight, about a finger's width above the wrist bone."))
                    }
                }
            }
        }
    }

    private var stayConnectedText: Text {
        #if os(iOS)
        Text("Keep NOOP connected to the strap overnight: turn off Low Power Mode and turn on Background App Refresh for NOOP (Settings → General → Background App Refresh).")
        #else
        Text("Keep NOOP running and your Mac awake near the strap overnight.")
        #endif
    }

    private func fixRow(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            text
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Formatting

    private func fact(_ label: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            value.font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func clock(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
    }

    private func sleepText(start: Int, end: Int) -> String {
        let minutes = max(0, end - start) / 60
        return "\(clock(start)) – \(clock(end)) · \(minutes / 60) h \(minutes % 60) min"
    }

    private func hoursText(_ hours: Double) -> String {
        hours.formatted(.number.precision(.fractionLength(1))) + " h"
    }

    private func percentText(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The title row of a screen presented as a sheet: the title and a close button, with no navigation bar.
struct SheetTitleBar: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(StrandPalette.surfaceRaised)
    }
}
