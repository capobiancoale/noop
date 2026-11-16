import SwiftUI
import StrandDesign
import WhoopStore

/// #590 — on-device storage diagnostics. iOS users saw "Documents & Data" balloon to ~19 GB after an
/// Apple Health import: the document picker's `asCopy:true` duplicate sat in `Documents/Inbox/` forever
/// and the WAL never truncated. AppModel now reclaims both automatically (Inbox cleanup on import +
/// launch, WAL truncate after each import); this screen makes the footprint VISIBLE and gives a manual
/// "Clean up now" escape hatch for anyone who already grew a backlog before the fix shipped.
///
/// Read-only otherwise: it shows the database size, the leftover Inbox size, and any stranded import
/// temp files. The button purges Inbox + temp and truncates the WAL — never touches live rows.
struct StorageView: View {
    @EnvironmentObject var model: AppModel

    @State private var report: AppModel.StorageReport?
    @State private var loading = true
    @State private var cleaning = false
    @State private var lastCleanedSummary: String?

    // Old sensor data (opt-in compaction)
    @State private var keepDays = CompactionPrefs.keepFullResolutionDays()
    @State private var preview: StreamCompactionReport?
    @State private var previewing = false
    @State private var previewFailed = false
    @State private var compacting = false
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var runSummary: CompactionRunSummary?
    @State private var runFailed = false
    @State private var showConfirm = false
    @State private var reclaimable: Int64?
    @State private var reclaiming = false
    @State private var reclaimMessage: String?
    @State private var backingUp = false
    @State private var backupMessage: String?

    var body: some View {
        ScreenScaffold(title: "Storage",
                       subtitle: "Where NOOP's on-device space is going, and a one-tap clean-up.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if loading && report == nil {
                    StatePill("Measuring…", tone: .accent, pulsing: true)
                        .staggeredAppear(index: 0)
                } else if let report {
                    breakdownCard(report).staggeredAppear(index: 0)
                    cleanUpCard(report).staggeredAppear(index: 1)
                    oldDataCard(report).staggeredAppear(index: 2)
                } else {
                    DataPendingNote(title: "Storage unavailable",
                                    message: "Couldn't read the local store right now. Try again in a moment.",
                                    symbol: "internaldrive")
                        .staggeredAppear(index: 0)
                }
                explainerCard.staggeredAppear(index: 3)
            }
        }
        .task { await load() }
    }

    // MARK: - Cards

    private func breakdownCard(_ r: AppModel.StorageReport) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("On-device footprint")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                row(icon: "cylinder.split.1x2",
                    label: "Health database",
                    bytes: r.db,
                    tint: StrandPalette.accent)
                Divider().overlay(StrandPalette.hairline)
                row(icon: "tray.full",
                    label: "Leftover import copies",
                    bytes: r.inbox,
                    tint: r.inbox > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary,
                    note: r.inbox > 0 ? "Reclaimable" : nil)
                Divider().overlay(StrandPalette.hairline)
                row(icon: "clock.arrow.circlepath",
                    label: "Import temp files",
                    bytes: r.importTemp,
                    tint: r.importTemp > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary,
                    note: r.importTemp > 0 ? "Reclaimable" : nil)
            }
        }
    }

    private func cleanUpCard(_ r: AppModel.StorageReport) -> some View {
        let reclaimable = r.inbox + r.importTemp
        return StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Clean up")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(reclaimable > 0
                     ? "There's about \(Self.format(reclaimable)) of leftover import scratch space to reclaim. This never removes your imported data."
                     : "Nothing to reclaim right now. NOOP already cleans up import scratch space automatically.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastCleanedSummary {
                    Text(lastCleanedSummary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusPositive)
                }

                Button {
                    Task { await cleanUp() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if cleaning { ProgressView().controlSize(.small) }
                        Text(cleaning ? "Cleaning up…" : "Clean up now")
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(cleaning || reclaimable == 0)
                .accessibilityLabel("Clean up leftover import files")
            }
        }
    }

    // MARK: - Old sensor data (opt-in)

    private func daysLabel(_ n: Int) -> String {
        n == 0 ? String(localized: "Never") : String(localized: "\(n) days")
    }

    private func oldDataCard(_ r: AppModel.StorageReport) -> some View {
        let canRun = CompactionPrefs.engineGuardInstalled && keepDays > 0 && !compacting
        return StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Old sensor data")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("The strap records your heart rate every second, and that takes most of the space. You can keep that detail only for recent days. For older days NOOP keeps one heart-rate value per minute.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Kept: your scores, sleep, workouts, daily values and minute-level heart rate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusPositive)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Given up for the older days: second-by-second zoom on the heart-rate timeline, and recalculating those nights when an algorithm improves. This cannot be undone.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Keep full detail for", selection: $keepDays) {
                    ForEach(CompactionPrefs.choices, id: \.self) { n in
                        Text(daysLabel(n)).tag(n)
                    }
                }
                .pickerStyle(.menu)
                .disabled(compacting)
                .onChange(of: keepDays) { newValue in
                    CompactionPrefs.setKeepFullResolutionDays(newValue)
                    preview = nil
                    previewFailed = false
                }

                if !CompactionPrefs.engineGuardInstalled {
                    Text("Compacting is switched off in this version until the scoring engine is updated to leave compacted days alone. You can still preview.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await runPreview() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if previewing { ProgressView().controlSize(.small) }
                        Text(previewing ? "Checking…" : "Preview")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .disabled(keepDays == 0 || previewing || compacting)

                if let preview {
                    Text(preview.rowsRemoved == 0
                         ? String(localized: "Nothing to compact for this setting.")
                         : String(localized: "About \(preview.rowsRemoved.formatted()) rows would be removed, roughly \(Self.format(preview.estimatedBytes)). The file only gets smaller after \"Reclaim space\"."))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if previewFailed {
                    Text("Couldn't read the store for a preview.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }

                Button {
                    showConfirm = true
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if compacting { ProgressView().controlSize(.small) }
                        Text(compacting ? "Compacting…" : "Compact now")
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(!canRun)
                .confirmationDialog(
                    String(localized: "Compact data older than \(keepDays) days?"),
                    isPresented: $showConfirm, titleVisibility: .visible) {
                    Button("Compact now", role: .destructive) { Task { await runCompaction() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Second-by-second heart rate older than \(keepDays) days will be replaced by one value per minute. This cannot be undone. Make a backup first.")
                }

                if compacting && progressTotal > 0 {
                    ProgressView(value: Double(progressDone), total: Double(progressTotal))
                    Text("\(progressDone) of \(progressTotal) days")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if let runSummary {
                    Text(runResultText(runSummary))
                        .font(StrandFont.footnote)
                        .foregroundStyle(runSummary.finished ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if runFailed {
                    Text("Compaction stopped because of an error. Nothing was left half-done; you can try again.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(StrandPalette.hairline)

                Button {
                    Task { await runBackup() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if backingUp { ProgressView().controlSize(.small) }
                        Text(backingUp ? "Saving backup…" : "Back up first…")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .disabled(backingUp || compacting)
                if let backupMessage {
                    Text(backupMessage)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(StrandPalette.hairline)

                Text("Reclaim space")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(reclaimable.map { String(localized: "Deleted rows leave free room inside the database file (about \(Self.format($0)) now). Reclaim space rewrites the file so it shrinks. It needs free storage at least as large as the database, can take a while, and is never run automatically.") }
                     ?? String(localized: "Deleted rows leave free room inside the database file. Reclaim space rewrites the file so it shrinks. It needs free storage at least as large as the database, can take a while, and is never run automatically."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await runReclaim() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if reclaiming { ProgressView().controlSize(.small) }
                        Text(reclaiming ? "Reclaiming…" : "Reclaim space")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .disabled(reclaiming || compacting)
                if let reclaimMessage {
                    Text(reclaimMessage)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runResultText(_ s: CompactionRunSummary) -> String {
        let rows = s.rowsRemoved.formatted()
        let sizes: String
        if let b = s.dbBefore, let a = s.dbAfter {
            sizes = String(localized: "Database before: \(Self.format(b)), after: \(Self.format(a)).")
        } else {
            sizes = ""
        }
        let head = s.finished
            ? String(localized: "Done: \(rows) rows removed.")
            : String(localized: "Stopped early: \(rows) rows removed so far.")
        return sizes.isEmpty ? head : head + " " + sizes
    }

    private var explainerCard: some View {
        DataPendingNote(
            title: "Why does this grow?",
            message: "When you import an Apple Health or WHOOP export, iOS hands NOOP a private copy of the file. NOOP reads it, saves your data into the health database, then deletes the copy. Older builds didn't delete every copy. This screen reclaims any that were left behind.",
            symbol: "questionmark.circle")
    }

    // MARK: - Row

    private func row(icon: String, label: LocalizedStringKey, bytes: Int64?,
                     tint: Color, note: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let note {
                    Text(note)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Text(bytes.map(Self.format) ?? "—")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        let r = await model.storageReport()
        report = r
        reclaimable = await model.reclaimableDatabaseBytes()
        loading = false
    }

    private func runPreview() async {
        guard !previewing else { return }
        previewing = true
        previewFailed = false
        let r = await model.previewCompaction(keepDays: keepDays)
        preview = r
        previewFailed = (r == nil)
        previewing = false
    }

    private func runCompaction() async {
        guard !compacting else { return }
        compacting = true
        runSummary = nil
        runFailed = false
        progressDone = 0
        progressTotal = 0
        let result = await model.compactOldSensorData(keepDays: keepDays, manual: true,
                                                      progress: { done, total in
            Task { @MainActor in
                progressDone = done
                progressTotal = total
            }
        })
        runSummary = result
        runFailed = (result == nil)
        preview = nil
        report = await model.storageReport()
        reclaimable = await model.reclaimableDatabaseBytes()
        compacting = false
    }

    private func runBackup() async {
        guard !backingUp else { return }
        backingUp = true
        let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
        switch result {
        case .exported(let url):
            backupMessage = String(localized: "Backup saved to \(url.lastPathComponent).")
        case .failure(let message):
            backupMessage = message
        case .cancelled, .imported:
            backupMessage = nil
        }
        backingUp = false
    }

    private func runReclaim() async {
        guard !reclaiming else { return }
        reclaiming = true
        reclaimMessage = nil
        let outcome = await model.reclaimDatabaseSpace()
        switch outcome {
        case .some(.reclaimed(let before, let after)):
            reclaimMessage = String(localized: "Database went from \(Self.format(before)) to \(Self.format(after)).")
        case .some(.notEnoughFreeSpace(let needed, let available)):
            reclaimMessage = String(localized: "Not enough free storage: \(Self.format(needed)) needed, \(Self.format(available)) available. Nothing was changed.")
        case .some(.integrityProblem):
            reclaimMessage = String(localized: "The database did not pass its health check, so nothing was changed.")
        case .some(.unavailable), .none:
            reclaimMessage = String(localized: "Couldn't reclaim space right now. Nothing was changed.")
        }
        report = await model.storageReport()
        reclaimable = await model.reclaimableDatabaseBytes()
        reclaiming = false
    }

    private func cleanUp() async {
        guard !cleaning else { return }
        cleaning = true
        let before = (report?.inbox ?? 0) + (report?.importTemp ?? 0)
        let r = await model.cleanUpStorage()
        let after = r.inbox + r.importTemp
        let freed = max(0, before - after)
        report = r
        lastCleanedSummary = freed > 0 ? String(localized: "Reclaimed \(Self.format(freed)).") : String(localized: "Already clean.")
        cleaning = false
    }

    /// Human byte size, decimal (matches iOS Settings' "Documents & Data" presentation).
    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}
