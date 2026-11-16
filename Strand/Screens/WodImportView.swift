#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WhoopStore
import StrandImport

// MARK: - WOD import (paste text → structured WODs)
//
// The low-friction path for logging WODs: the athlete gets the workout as a PHOTO, hands the photo to
// any capable AI with the prompt from `WodTextImport.aiPrompt` ("Copy AI prompt"), pastes the AI's
// reply here, checks the preview and saves — one or many WODs, with movements, the prescribed (RX) and
// actually-lifted loads all filled in. No field-by-field typing. The text is read as it is typed or
// pasted, so the preview and Save follow the box with no extra tap (an Analyze button under the box
// sat behind the keyboard, and Save stayed off until it was tapped). Parsing is the pure
// `WodTextImport` in WhoopStore; this screen is just the paste box, preview and save.

struct WodImportView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    /// Called after a successful save so the list can refresh.
    let onSaved: () -> Void

    @State private var text = ""
    @State private var parsed: [WodLogRow] = []
    @State private var didParse = false
    @State private var saving = false
    @State private var csvNote: String?
    /// Whether the preview came from a spreadsheet, which an empty paste box must not clear.
    @State private var fromCsv = false
    /// WODs already in the log, to spot rows imported before (same day + title).
    @State private var existing: [WodLogRow] = []
    /// Import rows that match a WOD already in the log anyway (off: they are skipped).
    @State private var importDuplicates = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .font(.callout)
                        .focused($editorFocused)
                } header: {
                    Text("Paste WOD text")
                } footer: {
                    Text("One block per WOD; separate several with a line of “---”. Labels like Name, Movements, RX and Result are understood in English and Italian.")
                }

                if !parsed.isEmpty {
                    Section("Preview") {
                        ForEach(parsed) { w in
                            WodPreviewRow(wod: w, skipped: !importDuplicates && duplicateIds.contains(w.id))
                        }
                    }
                    if !duplicateIds.isEmpty { duplicatesSection }
                    Section {
                        Button { saveAll() } label: {
                            Label(saveTitle, systemImage: "checkmark.circle.fill")
                                .font(.headline)
                        }
                        .disabled(saving || rowsToSave.isEmpty)
                    }
                } else if didParse && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Text("Couldn't find a WOD in that text. Check the format, or tap “Copy AI prompt” and let an AI convert your photo.")
                            .foregroundStyle(.secondary).font(.subheadline)
                    }
                }

                Section {
                    Button { pasteFromClipboard() } label: {
                        Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button { copyAIPrompt() } label: {
                        Label("Copy AI prompt (for your photo)", systemImage: "sparkles")
                    }
                }

                Section {
                    Button { chooseCsvFile() } label: {
                        Label("Import from CSV file", systemImage: "tablecells")
                    }
                    Button { copyCsvTemplate() } label: {
                        Label("Copy CSV template", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Or import a spreadsheet")
                } footer: {
                    if let note = csvNote {
                        Text(note).foregroundStyle(.secondary)
                    } else {
                        Text("One row per movement; columns date, name, movement, reps, rx_kg, my_kg, result… Rows with the same date + name become one WOD.")
                    }
                }

            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Import WODs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save all") { saveAll() }
                        .disabled(rowsToSave.isEmpty || saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                }
            }
            // Read the box shortly after typing pauses; a new keystroke cancels the pending read.
            .task { existing = await repo.allWods() }
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                analyze()
            }
        }
    }

    private var saveTitle: String {
        rowsToSave.count == 1
            ? String(localized: "Save WOD")
            : String(localized: "Save \(rowsToSave.count) WODs")
    }

    // MARK: Rows already in the log

    private var duplicateIds: Set<String> {
        Set(WodImportMatch.split(imported: parsed, existing: existing).duplicates.map(\.id))
    }

    /// What Save writes: everything, or only the rows not already in the log.
    private var rowsToSave: [WodLogRow] {
        importDuplicates ? parsed : parsed.filter { !duplicateIds.contains($0.id) }
    }

    private var duplicatesNote: String {
        let n = duplicateIds.count
        if importDuplicates {
            return n == 1
                ? String(localized: "1 WOD is already in your log (same day and name). It will be added again.")
                : String(localized: "\(n) WODs are already in your log (same day and name). They will be added again.")
        }
        return n == 1
            ? String(localized: "1 WOD is already in your log (same day and name) and will be skipped.")
            : String(localized: "\(n) WODs are already in your log (same day and name) and will be skipped.")
    }

    private var duplicatesSection: some View {
        Section {
            Text(duplicatesNote).font(.subheadline).foregroundStyle(.secondary)
            Toggle("Import them anyway", isOn: $importDuplicates)
        }
    }

    private func analyze() {
        // An empty box leaves a spreadsheet import's preview alone.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !fromCsv { parsed = [] }
            return
        }
        parsed = WodTextImport.parse(text)
        fromCsv = false
        didParse = true
    }

    private func pasteFromClipboard() {
        if let s = UIPasteboard.general.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = s
            editorFocused = false
            analyze()
        }
    }

    private func copyAIPrompt() {
        UIPasteboard.general.string = WodTextImport.aiPrompt
    }

    private func copyCsvTemplate() {
        UIPasteboard.general.string = WodCsvImport.template
        csvNote = String(localized: "Template copied — paste it into a spreadsheet.")
    }

    private func chooseCsvFile() {
        Task {
            guard let url = await DocumentPicker.importFile([.commaSeparatedText, .plainText]) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                csvNote = String(localized: "Couldn't read that file.")
                return
            }
            let result = WodCsvImport.parse(data: data)
            guard !result.fileTooLarge else {
                csvNote = String(localized: "That file is too large.")
                return
            }
            parsed = result.wods
            fromCsv = true
            didParse = true
            if result.wods.isEmpty {
                csvNote = String(localized: "No WODs found — check the columns (date, name, movement…).")
            } else if result.skippedRows > 0 {
                csvNote = String(localized: "Imported \(result.importedWods) WODs · \(result.skippedRows) rows skipped.")
            } else {
                csvNote = String(localized: "Imported \(result.importedWods) WODs.")
            }
        }
    }

    private func saveAll() {
        guard !rowsToSave.isEmpty else { return }
        saving = true
        let all = parsed
        let anyway = importDuplicates
        Task {
            // Re-read the log so a WOD saved a moment ago still counts as already present.
            let current = await repo.allWods()
            let rows = anyway ? all : WodImportMatch.split(imported: all, existing: current).fresh
            for r in rows { await repo.saveWod(r) }
            await MainActor.run { onSaved(); dismiss() }
        }
    }
}

// MARK: - Preview row

private struct WodPreviewRow: View {
    let wod: WodLogRow
    /// True for a row already in the log that Save will leave out.
    var skipped = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(wod.title).font(.headline)
                if let rx = wod.rx { WodRxBadge(rx: rx) }
                Spacer()
                if let r = WodFormat.result(wod) {
                    Text(r).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(WodFormat.typeLine(wod))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(wod.movements.enumerated()), id: \.offset) { _, m in
                Text("• " + WodFormat.movement(m))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notes = wod.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            if skipped {
                Text("Already in your log, skipped")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .opacity(skipped ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}

#endif
