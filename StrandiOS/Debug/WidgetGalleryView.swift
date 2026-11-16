#if DEBUG
import SwiftUI
import WidgetKit
import StrandDesign

/// DEBUG-only widget gallery (`--demo-screen widgets`): renders both widgets in every family at their real point
/// size, for three sample snapshots, on a wallpaper-like background. The widget view code is compiled into the app
/// for this (see project.yml), so what is drawn here is the real `NOOPWidgetView` / `NOOPPlanWidgetView`.
///
/// Limits: the system's own content margins, corner radius, tinted / accented rendering and StandBy scaling are
/// not reproduced; Home Screen tiles get a 16 pt inset and a rounded `surfaceBase` card as an approximation.
struct WidgetGalleryView: View {

    private enum Scheme: String, CaseIterable, Identifiable {
        case auto = "Auto", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .auto: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private struct Sample: Identifiable {
        let id: String
        let title: String
        let snapshot: WidgetSnapshot
    }

    @State private var scheme: Scheme = .auto

    private static let day = WidgetSnapshot.planDayKey(at: Date())

    /// Push day with a session at 19:00, the meal window and bedtime with wake time.
    private static var pushDay: WidgetSnapshot {
        WidgetSnapshot(recovery: 76, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 12, rest: 82, hrv: 64, restingHr: 52,
                       planTraining: "push", planReason: "chargeHigh", planReasonValue: 76,
                       planSleepMinutes: 510, planBedtimeMinutes: 22 * 60 + 45,
                       planEnergyLow: 2_700, planEnergyHigh: 3_000,
                       planProteinLow: 130, planProteinHigh: 180,
                       planCarbsLow: 380, planCarbsHigh: 520,
                       planFocus: "sleepDebt", planFocusValue: 75, planDay: day,
                       planRestDay: false, planSessionStartMinutes: 19 * 60,
                       planMealFromMinutes: 16 * 60, planMealToMinutes: 16 * 60 + 30,
                       planWakeMinutes: 7 * 60 + 15, planThresholdsPersonal: true)
    }

    /// Rest day by schedule: the level is only "if you train".
    private static var restDay: WidgetSnapshot {
        WidgetSnapshot(recovery: 58, bpm: 61, batteryPct: 63, bonded: true, updated: Date(),
                       effort: 12, rest: 82, hrv: 55, restingHr: 54,
                       planTraining: "maintain", planReason: "shortSleep",
                       planSleepMinutes: 510, planBedtimeMinutes: 22 * 60 + 30,
                       planEnergyLow: 2_300, planEnergyHigh: 2_550,
                       planProteinLow: 130, planProteinHigh: 170,
                       planCarbsLow: 270, planCarbsHigh: 380,
                       planFocus: "lowSleepAverage", planFocusValue: 415, planDay: day,
                       planRestDay: true, planWakeMinutes: 7 * 60, planThresholdsPersonal: false)
    }

    /// No plan stored for today: the "Open NOOP" state.
    private static var noPlan: WidgetSnapshot {
        WidgetSnapshot(recovery: 41, bpm: nil, batteryPct: 20, bonded: false, updated: Date(),
                       effort: nil, rest: nil, hrv: nil, restingHr: nil)
    }

    private static let samples: [Sample] = [
        Sample(id: "push", title: "Push day, session 19:00", snapshot: pushDay),
        Sample(id: "rest", title: "Rest day", snapshot: restDay),
        Sample(id: "none", title: "No plan", snapshot: noPlan)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Appearance", selection: $scheme) {
                    ForEach(Scheme.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(Self.samples) { sample in
                    sampleSection(sample)
                }
            }
            .padding(16)
        }
        .background(wallpaper.ignoresSafeArea())
        .preferredColorScheme(scheme.colorScheme)
    }

    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.46),
                                Color(red: 0.55, green: 0.24, blue: 0.52),
                                Color(red: 0.92, green: 0.52, blue: 0.40)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Sections

    private func sampleSection(_ sample: Sample) -> some View {
        let entry = NOOPEntry(date: Date(), snapshot: sample.snapshot)
        return VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: sample.title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            widgetGroup("NOOP Charge", entry: entry, plan: false)
            widgetGroup("NOOP Today's plan", entry: entry, plan: true)
        }
    }

    private func widgetGroup(_ name: String, entry: NOOPEntry, plan: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            home(.systemSmall, width: 170, height: 170, entry: entry, plan: plan)
            home(.systemMedium, width: 364, height: 170, entry: entry, plan: plan)
            home(.systemLarge, width: 364, height: 382, entry: entry, plan: plan)
            // Lock Screen widgets are always drawn light-on-dark.
            lockScreen {
                accessory(.accessoryRectangular, width: 172, height: 76, entry: entry, plan: plan)
                accessory(.accessoryCircular, width: 76, height: 76, entry: entry, plan: plan)
            }
            inlineLine(entry: entry, plan: plan)
        }
    }

    // MARK: - Frames

    private func content(_ family: WidgetFamily, entry: NOOPEntry, plan: Bool) -> some View {
        Group {
            if plan {
                NOOPPlanWidgetView(entry: entry, familyOverride: family)
            } else {
                NOOPWidgetView(entry: entry, familyOverride: family)
            }
        }
    }

    /// A Home Screen widget: a rounded card of the real point size with the usual 16 pt content margin.
    private func home(_ family: WidgetFamily, width: CGFloat, height: CGFloat,
                      entry: NOOPEntry, plan: Bool) -> some View {
        content(family, entry: entry, plan: plan)
            .frame(width: width - 32, height: height - 32)
            .padding(16)
            .frame(width: width, height: height)
            .background(StrandPalette.surfaceBase, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func lockScreen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
    }

    /// A Lock Screen accessory on the translucent plate the system draws behind it.
    private func accessory(_ family: WidgetFamily, width: CGFloat, height: CGFloat,
                           entry: NOOPEntry, plan: Bool) -> some View {
        let isCircle = family == .accessoryCircular
        return content(family, entry: entry, plan: plan)
            .frame(width: width, height: height)
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: isCircle ? width / 2 : 14,
                                                                        style: .continuous))
    }

    private func inlineLine(entry: NOOPEntry, plan: Bool) -> some View {
        content(.accessoryInline, entry: entry, plan: plan)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: 220, height: 24, alignment: .leading)
            .background(Color.white.opacity(0.18), in: Capsule())
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
    }
}
#endif
