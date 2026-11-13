import SwiftUI
import UIKit
import StrandDesign

/// Colours shared by both widgets. Charge / Effort / Rest reuse what the widget always used.
enum WidgetColors {
    static func charge(_ r: Int?) -> Color {
        guard let r else { return StrandPalette.textTertiary }
        return r >= 67 ? StrandPalette.statusPositive : r >= 34 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }

    /// Effort is on the 0-100 axis (`StrainScorer.maxStrain == 100`), the same input as the Today Effort tile.
    static func effort(_ e: Int?) -> Color {
        guard let e else { return StrandPalette.textTertiary }
        return StrandPalette.effortTint(fraction: Double(e) / 100)
    }

    static func rest(_ r: Int?) -> Color {
        guard let r else { return StrandPalette.textTertiary }
        return StrandPalette.recoveryColor(Double(r))
    }

    /// Blue-grey for the easy day: calm, readable on the dark canvas and on the light one.
    static let easy = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.56, green: 0.66, blue: 0.80, alpha: 1)   // #8FA9CC
            : UIColor(red: 0.29, green: 0.40, blue: 0.52, alpha: 1)   // #4A6685
    })

    /// Push green and maintain amber come from the palette's status colours (both have a light variant).
    static func training(_ t: WidgetPlan.Training) -> Color {
        switch t {
        case .push: return StrandPalette.statusPositive
        case .maintain: return StrandPalette.statusWarning
        case .easy: return easy
        }
    }
}

/// Text sizes: at most two sizes plus one caption per widget. `big` for the headline, `mid` for figures.
enum WidgetSize {
    static let big: CGFloat = 26
    static let mid: CGFloat = 16
    static let caption: CGFloat = 11
}

/// A score ring with the number inside. The ring is the accentable element in tinted mode.
struct ScoreRing: View {
    let value: Int?
    let tint: Color
    let size: CGFloat
    let lineWidth: CGFloat
    let valueSize: CGFloat

    private var fraction: Double {
        Double(min(max(value ?? 0, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.textTertiary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Text(value.map { $0.formatted() } ?? "–")
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, lineWidth + 2)
        }
        .frame(width: size, height: size)
    }
}

/// A figure over its caption.
struct StatCell: View {
    let label: LocalizedStringKey
    let value: String?
    var tint: Color = StrandPalette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value ?? "–")
                .font(.system(size: WidgetSize.mid, weight: .semibold, design: .rounded))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: WidgetSize.caption, weight: .medium))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The training word (Push / Maintain / Easy day), coloured. Never truncated: it shrinks instead.
struct PlanWord: View {
    let plan: WidgetPlan
    let size: CGFloat

    var body: some View {
        Text(verbatim: plan.word)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(WidgetColors.training(plan.training))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .widgetAccentable()
    }
}

/// Small caption text in the secondary colour.
struct CaptionText: View {
    let text: String
    var lines: Int = 2
    var color: Color = StrandPalette.textSecondary

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: WidgetSize.caption, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Green when the strap is bonded, red when not (the Charge widget's existing indicator).
struct BondDot: View {
    let bonded: Bool

    var body: some View {
        Circle()
            .fill(bonded ? StrandPalette.statusPositive : StrandPalette.statusCritical)
            .frame(width: 8, height: 8)
    }
}

/// A percent figure in the device locale ("81%"), nil stays nil.
func widgetPercent(_ v: Int?) -> String? {
    v.map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) }
}
