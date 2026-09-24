#if os(iOS)
import SwiftUI
import StrandDesign

/// Floating progress card above the tab bar while Apple Health data comes in: the one-time history
/// import, or a sync the user started. It shows that the import is working, how far it has got and what it
/// is reading, with a pause button, while the rest of NOOP stays usable. Only this view observes the
/// HealthKit bridge, so the tab shell doesn't re-render on every progress step. A quiet refresh of recent
/// days shows only on the Apple Health screen.
struct HealthSyncBanner: View {
    @EnvironmentObject private var health: HealthKitBridge

    var body: some View {
        let visible = health.progress?.showsBanner == true
        VStack(spacing: 0) {
            if visible, let p = health.progress {
                card(p)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
    }

    private func card(_ p: HealthKitBridge.SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(StrandPalette.metricCyan)
                    .accessibilityHidden(true)
                Text(p.isHistoryImport ? String(localized: "Importing from Apple Health")
                     : String(localized: "Updating from Apple Health"))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                Text(p.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                Button { health.pauseSync() } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause import")
            }
            ProgressView(value: p.fraction)
                .tint(StrandPalette.metricCyan)
            Text(verbatim: "\(p.step) · \(p.period)")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 22)
        .accessibilityElement(children: .contain)
    }
}
#endif
