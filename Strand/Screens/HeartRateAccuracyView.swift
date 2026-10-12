import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Heart-rate accuracy
//
// "Is my strap reading too high?" A wrist strap reads the pulse optically, and nothing in the phone can prove
// its absolute accuracy. What this screen does honestly offer:
//   1. whether the strap's heart rate agrees with its OWN beat-to-beat timing over the last 24 hours
//      (StrandAnalytics.HeartRateAccuracy.rrConsistency): a disturbed optical signal shows as a gap;
//   2. a 30-second pulse count against the strap (HeartRateAccuracy.palpation), the one check that is
//      independent of the sensor;
//   3. the wearer's own sleeping and waking numbers, so "high" is judged against their baseline, and the
//      max heart rate the zones and Effort are built on.
// Data: Repository+HeartRateAccuracy. Informational only, not a medical device.

struct HeartRateAccuracyView: View {
    /// Non-nil when the screen is shown as a sheet: adds a title bar with a close button.
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var report: Repository.HeartRateAccuracyReport?
    @State private var loaded = false

    var body: some View {
        Group {
            if let onClose {
                VStack(spacing: 0) {
                    SheetTitleBar(title: "Heart-rate accuracy", onClose: onClose)
                    Divider().overlay(StrandPalette.hairline)
                    ScreenScaffold(title: nil, onRefresh: { await load() }) { sections }
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
            } else {
                ScreenScaffold(title: "Heart-rate accuracy",
                               subtitle: "Is your strap's heart rate consistent, and does it match your pulse?",
                               onRefresh: { await load() }) { sections }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 600)
        #endif
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            agreementCard
            PulseCountCard()
            contextCard
            VStack(alignment: .leading, spacing: 6) {
                Text("Informational only, not medical advice.")
                Text("Optical wrist heart rate can read high during intense, rhythmic movement, when the sensor can lock onto the movement cadence instead of the pulse. That comes from the sensor, not the app.")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        report = await repo.heartRateAccuracyReport()
        loaded = true
    }

    // MARK: Strap against its own beats

    private var agreementCard: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Strap vs beat-to-beat (last 24 h)")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if let a = report?.agreement {
                    Text(verbatim: percentText(a.shareWithin5Bpm))
                        .font(StrandFont.number(34))
                        .foregroundStyle(a.shareWithin5Bpm >= 0.9 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    Text("The strap's heart rate matches its own beat-to-beat timing within 5 bpm \(percentText(a.shareWithin5Bpm)) of the time (average difference \(signedText(a.meanBias)) bpm).")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Compared over \(a.n) seconds that had clean beats around them.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text("A large difference means motion artefacts or a loose fit at those moments. Both numbers come from the same optical sensor, so this checks consistency, not absolute accuracy.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if loaded {
                    Text("Not enough data to compare yet. This needs the strap connected for a while, so it can record heart rate and beat-to-beat intervals together.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: In context

    private var contextCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your heart rate in context")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("\"High\" is best judged against your own numbers.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                if let s = report?.sleeping {
                    fact("Sleeping floor, last night", bpmText(Double(s.floorBpm)))
                    fact("Night average, last night", bpmText(s.meanBpm))
                } else if loaded {
                    fact("Last night", "–")
                }
                if let w = report?.waking {
                    fact("Calmest waking stretches", bpmText(w.restingBpm))
                    fact("Typical while awake", bpmText(w.typicalBpm))
                    fact("Top of your usual range", bpmText(w.highBpm))
                    Text("Over the last 7 days, from 5-minute averages outside sleep.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else if loaded {
                    fact("Waking range", "–")
                    Text("Needs about two hours of waking heart rate from the last 7 days.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Divider().overlay(StrandPalette.hairline)
                maxHeartRateBlock
            }
        }
    }

    /// The max heart rate the zones and Effort use, editable here exactly as in Settings → Profile
    /// (the same two stored values, so the two places always agree).
    private var maxHeartRateBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            fact("Max heart rate used for zones", bpmText(Double(profile.hrMax)))
            HStack(spacing: 12) {
                Text("Age").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text(verbatim: "\(profile.age)").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Stepper("Age", value: $profile.age, in: 13...100)
                    .labelsHidden()
                    .accessibilityLabel("Age, \(profile.age) years")
            }
            HStack(spacing: 12) {
                Text("Max heart rate override").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                if profile.hrMaxOverride > 0 {
                    Text(verbatim: "\(profile.hrMaxOverride)")
                        .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("Auto").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textTertiary)
                }
                Stepper("Max heart rate override", value: $profile.hrMaxOverride, in: 0...230, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(hrMaxOverrideLabel)
            }
            Text("Automatic: 208 − 0.7 × age (Tanaka et al., J Am Coll Cardiol 2001), a population average that can be 10 bpm or more off for one person. If your real maximum is higher, hard efforts look harder than they are; set your measured maximum here. The same values live in Settings → Profile.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Formatting

    private var hrMaxOverrideLabel: String {
        profile.hrMaxOverride == 0
            ? String(localized: "Max heart rate override, automatic")
            : String(localized: "Max heart rate override, \(profile.hrMaxOverride) bpm")
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func bpmText(_ v: Double) -> String { "\(Int(v.rounded())) bpm" }

    private func percentText(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }

    private func signedText(_ v: Double) -> String { HeartRateAccuracyFormat.signed(v) }
}

/// Number formatting shared by the accuracy screen's cards.
enum HeartRateAccuracyFormat {
    /// "+2", "-3" or "0": a whole-bpm difference with its sign, so a rounded zero never reads "-0".
    static func signed(_ v: Double) -> String {
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }
}

// MARK: - Count it yourself

/// The 30-second pulse check. Start → a countdown while the person counts their pulse at the wrist or neck,
/// with the strap's live bpm beside it → they enter the beats → the two numbers side by side. Owns
/// `LiveState` so the ~1 Hz heart-rate updates redraw only this card.
private struct PulseCountCard: View {
    @EnvironmentObject private var live: LiveState

    private static let countSeconds = 30

    private enum Phase: Equatable {
        case idle
        case counting
        case asking
        case result(HeartRateAccuracy.PalpationResult?)
    }

    @State private var phase: Phase = .idle
    @State private var remaining = PulseCountCard.countSeconds
    @State private var samples: [(ts: Int, bpm: Double)] = []
    @State private var windowStart = 0
    @State private var countText = ""
    @State private var countTask: Task<Void, Never>?
    @State private var buzz = 0
    @FocusState private var focused: Bool

    var body: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Count it yourself (30 s)")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                switch phase {
                case .idle: idleView
                case .counting: countingView
                case .asking: askingView
                case .result(let r): resultView(r)
                }
            }
        }
        .liquidMediumHaptic(trigger: buzz)
        .onDisappear { countTask?.cancel() }
    }

    // MARK: Phases

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find your pulse at the wrist or the side of the neck and get ready to count each beat for 30 seconds. NOOP compares your count with what the strap reports over the same 30 seconds.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NoopButton("Start", systemImage: "play.fill", kind: .primary) { start() }
                .disabled(!canStart)
            if !canStart {
                Text("Connect your strap first.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var countingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(remaining)").font(StrandFont.number(48)).foregroundStyle(StrandPalette.textPrimary)
                Text("seconds left").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Count every beat you feel. Keep your arm still.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            if let hr = live.heartRate, hr > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Strap").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text(verbatim: "\(hr) bpm").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.metricRose)
                }
            }
            NoopButton("Cancel", kind: .tertiary) { cancel() }
        }
    }

    private var askingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time's up. How many beats did you count?")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 8) {
                TextField("e.g. 36", text: $countText)
                    .textFieldStyle(.plain)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .numericKeyboard()
                    .focused($focused)
                    .onSubmit(compare)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("beats").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(spacing: 12) {
                NoopButton("Compare", kind: .primary, action: compare)
                    .disabled(typedBeats == nil)
                NoopButton("Cancel", kind: .tertiary) { cancel() }
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func resultView(_ r: HeartRateAccuracy.PalpationResult?) -> some View {
        if let r {
            VStack(alignment: .leading, spacing: 12) {
                Text("You: \(bpmWhole(r.countedBpm)) bpm · Strap: \(bpmWhole(r.strapBpm)) bpm (\(HeartRateAccuracyFormat.signed(r.differenceBpm)))")
                    .font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if r.matches {
                    Text("That matches: the strap is within 5 bpm of your count.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    mismatchTips(r)
                }
                Text("One beat more or less in 30 seconds moves your count by 2 bpm, so a few bpm of difference is normal.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Check again", systemImage: "arrow.clockwise", kind: .secondary) { reset() }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Couldn't compare. Either the strap lost the connection during the count, or the number of beats doesn't look like a pulse. Try again.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Check again", systemImage: "arrow.clockwise", kind: .secondary) { reset() }
            }
        }
    }

    private func mismatchTips(_ r: HeartRateAccuracy.PalpationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if r.differenceBpm > 0 {
                    Text("The strap reads higher than your count by more than 5 bpm.")
                } else {
                    Text("The strap reads lower than your count by more than 5 bpm.")
                }
            }
            .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
            .fixedSize(horizontal: false, vertical: true)
            Text("Tighten the strap so it sits snugly, wear it a finger's width above the wrist bone, and stay still while you count. Then check again.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var canStart: Bool { live.connected && (live.heartRate ?? 0) > 0 }

    private var typedBeats: Int? {
        let text = countText.trimmingCharacters(in: .whitespaces)
        guard let n = Int(text), n > 0 else { return nil }
        return n
    }

    private func bpmWhole(_ v: Double) -> String { String(Int(v.rounded())) }

    private func start() {
        samples = []
        remaining = Self.countSeconds
        countText = ""
        let begin = Int(Date().timeIntervalSince1970)
        windowStart = begin
        phase = .counting
        buzz &+= 1
        countTask?.cancel()
        countTask = Task { @MainActor in
            // One reading per second, stamped by its position in the count: a steady heart rate that the
            // strap does not re-announce (it only notifies on change) still counts for its second.
            for tick in 0..<Self.countSeconds {
                if live.connected, let hr = live.heartRate, hr > 0 {
                    samples.append((ts: begin + tick, bpm: Double(hr)))
                }
                remaining = Self.countSeconds - tick
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            remaining = 0
            buzz &+= 1
            phase = .asking
        }
    }

    private func compare() {
        guard let beats = typedBeats else { return }
        focused = false
        let result = HeartRateAccuracy.palpation(strap: samples, start: windowStart,
                                                 seconds: Self.countSeconds, countedBeats: beats)
        phase = .result(result)
    }

    private func cancel() {
        countTask?.cancel()
        focused = false
        phase = .idle
    }

    private func reset() {
        countTask?.cancel()
        samples = []
        countText = ""
        phase = .idle
    }
}
