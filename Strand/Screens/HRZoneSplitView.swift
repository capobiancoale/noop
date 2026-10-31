import SwiftUI
import StrandDesign

// MARK: - Time in heart-rate zones
//
// The time a session spent in each heart-rate zone (Z1…Z5, from 50 % to 100 % of max heart rate in tenths,
// StrandAnalytics.HRZones): one bar split in the zones' colours, and under it each zone's share and time.
// Shared by a workout's detail and a WOD's screen; the live workout shows the same times under its zone
// rail as they build.

struct HRZoneSplitView: View {
    /// Minutes in zones 1…5 (index 0 = zone 1). Missing entries count as zero.
    let minutes: [Double]
    /// Outline the zone with the most time.
    var highlightBusiest = true

    private var zones: [Double] { (0..<5).map { minutes.indices.contains($0) ? max(0, minutes[$0]) : 0 } }

    var body: some View {
        let z = zones
        let total = z.reduce(0, +)
        let busiest = z.indices.max(by: { z[$0] < z[$1] }) ?? 0
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Rectangle()
                            .fill(StrandPalette.hrZoneColor(i + 1))
                            .frame(width: total > 0 ? max(0, CGFloat(z[i] / total) * (geo.size.width - 8)) : 0)
                            .overlay {
                                if highlightBusiest, i == busiest, total > 0 {
                                    Rectangle()
                                        .strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                                }
                            }
                    }
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Time in heart-rate zones"))
            .accessibilityValue(Text(verbatim: (1...5).map {
                "Z\($0) " + Self.clock(minutes: z[$0 - 1])
            }.joined(separator: ", ")))
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    stat(i + 1, minutes: z[i], total: total)
                }
            }
        }
    }

    private func stat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text(verbatim: "Z\(zone)").strandOverline()
            }
            Text(verbatim: Self.clock(minutes: minutes))
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: "\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "3:25" (minutes:seconds), or "1:02:05" past an hour.
    static func clock(minutes: Double) -> String {
        clock(seconds: minutes * 60)
    }

    static func clock(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3_600 { return String(format: "%d:%02d:%02d", s / 3_600, (s % 3_600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
