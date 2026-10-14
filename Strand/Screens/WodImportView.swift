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
                        ForEach(parsed) { w in WodPreviewRow(wod: w) }
                    }
                    Section {
                        Button { saveAll() } label: {
                            Label(saveTitle, systemImage: "checkmark.circle.fill")
                                .font(.headline)
                        }
                        .disabled(saving)
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
                        .disabled(parsed.isEmpty || saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                }
            }
            // Read the box shortly after typing pauses; a new keystroke cancels the pending read.
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                analyze()
            }
        }
    }

    private var saveTitle: String {
        parsed.count == 1
            ? String(localized: "Save WOD")
            : String(localized: "Save \(parsed.count) WODs")
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
        guard !parsed.isEmpty else { return }
        saving = true
        let rows = parsed
        Task {
            for r in rows { await repo.saveWod(r) }
            await MainActor.run { onSaved(); dismiss() }
        }
    }
}

// MARK: - Preview row

private struct WodPreviewRow: View {
    let wod: WodLogRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(wod.title).font(.headline)
                if let rx = wod.rx {
                    Text(rx ? "RX" : "Scaled")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((rx ? Color.green : Color.orange).opacity(0.22), in: Capsule())
                }
                Spacer()
                if let r = WodFormat.result(wod) {
                    Text(r).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(wod.type)
                if let f = wod.format, !f.isEmpty { Text("· \(f)") }
                Text("· \(WodFormat.day(wod.ts))")
            }
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
        }
        .padding(.vertical, 2)
    }
}

#endif
