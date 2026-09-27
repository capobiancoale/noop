import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

// MARK: - Resting heart rate, lying down
//
// The heart-rate ratio VO₂max (the value from WODs) is only as good as its resting heart rate, and its factor
// belongs to a resting heart rate measured supine and awake after 15 minutes of rest (Castagna et al., Eur J
// Appl Physiol 2022). This sheet runs that protocol with the strap: 15 minutes lying still, the value is the
// mean of the final 2 minutes (VO2maxEngine.supineRestingHR). A value measured the same way elsewhere can be
// typed instead.

struct RestingHRCaptureSheet: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case ready, capturing, done(Double), failed }
    private enum Field: Hashable { case bpm }

    @State private var phase: Phase = .ready
    @State private var start = 0
    @State private var now = 0
    @State private var samples: [HRSample] = []
    @State private var typed = ""
    @FocusState private var focused: Field?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var connected: Bool { live.bonded || live.streamingLiveHR }
    private var remaining: Int { max(0, VO2maxEngine.supineRestS - max(0, now - start)) }
    private var progress: Double { 1 - Double(remaining) / Double(VO2maxEngine.supineRestS) }
    private var typedBpm: Double? {
        Double(typed.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).flatMap {
            Repository.supineRestingHRPlausible.contains($0) ? $0 : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Resting heart rate, lying down").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text("For the VO₂max from your WODs.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            switch phase {
            case .ready: ready
            case .capturing: capturing
            case .done(let bpm): done(bpm)
            case .failed: failed
            }
            if phase == .ready || phase == .failed { manualEntry }
            HStack {
                Spacer()
                NoopButton(phase == .capturing ? "Stop" : "Close", kind: .tertiary) {
                    ScreenIdle.keepAwake(false)
                    dismiss()
                }
            }
        }
        .padding(NoopMetrics.space6)
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceOverlay)
        .keyboardDoneToolbar($focused)
        .interactiveDismissDisabled(phase == .capturing)
        .onReceive(timer) { _ in tick() }
        .onDisappear { ScreenIdle.keepAwake(false) }
    }

    // MARK: - Phases

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("1", String(localized: "Lie on your back in a quiet room, wearing the strap. Best in the morning, before coffee and training."))
            step("2", String(localized: "Tap Start and stay still and relaxed for 15 minutes: no phone, no talking."))
            step("3", String(localized: "NOOP takes the average of the last 2 minutes."))
            NoopButton("Start", systemImage: "bed.double", kind: .primary, fullWidth: true) { begin() }
                .disabled(!connected)
            if !connected {
                Text("Connect the strap first: the measurement reads your live heart rate.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
        }
    }

    private var capturing: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(StrandPalette.chargeColor.opacity(0.2), lineWidth: 10)
                Circle().trim(from: 0, to: progress)
                    .stroke(StrandPalette.chargeColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                VStack(spacing: 2) {
                    Text(verbatim: String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(StrandFont.number(40)).foregroundStyle(StrandPalette.textPrimary)
                    Text(live.heartRate.map { "\($0) bpm" } ?? "— bpm")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(width: 180, height: 180)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(remaining / 60) minutes left"))
            Text("Stay still and relaxed. The screen stays on.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity)
            if !connected {
                Text("The strap disconnected: the last 2 minutes need its heart rate.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
        }
    }

    private func done(_ bpm: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(Int(bpm.rounded()))").font(StrandFont.number(44)).foregroundStyle(StrandPalette.textPrimary)
                Text("bpm").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Text("Your resting heart rate, lying down (average of the last 2 minutes).")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            NoopButton("Save", systemImage: "checkmark", kind: .primary, fullWidth: true) { save(bpm) }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The strap sent too little heart rate in the last 2 minutes, so there is no value. Try again.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
            NoopButton("Try again", systemImage: "arrow.clockwise", kind: .secondary) { begin() }
                .disabled(!connected)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or type one measured the same way").strandOverline()
            HStack(spacing: 8) {
                TextField("e.g. 52", text: $typed)
                    .textFieldStyle(.plain)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .numericKeyboard()
                    .focused($focused, equals: .bpm)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("bpm").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                NoopButton("Save", kind: .secondary) { if let v = typedBpm { save(v) } }
                    .disabled(typedBpm == nil)
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: number).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.chargeColor)
            Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Capture

    private func begin() {
        samples = []
        start = Int(Date().timeIntervalSince1970)
        now = start
        phase = .capturing
        ScreenIdle.keepAwake(true)
    }

    /// Once a second: bank the live heart rate (only while the strap is connected, so a dropped link never
    /// repeats a stale value) and finish at 15 minutes.
    private func tick() {
        guard phase == .capturing else { return }
        now = Int(Date().timeIntervalSince1970)
        if connected, let hr = live.heartRate, hr > 0 { samples.append(HRSample(ts: now, bpm: hr)) }
        guard now - start >= VO2maxEngine.supineRestS else { return }
        ScreenIdle.keepAwake(false)
        phase = VO2maxEngine.supineRestingHR(samples, start: start).map { .done($0) } ?? .failed
    }

    private func save(_ bpm: Double) {
        let day = Repository.dayString(Date())
        Task { await repo.saveSupineRestingHR(day: day, bpm: bpm.rounded()) }
        dismiss()
    }
}
