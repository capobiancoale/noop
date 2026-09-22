#if os(iOS)
import SwiftUI
import UIKit
import WhoopStore

// MARK: - WOD import (paste text → structured WODs)
//
// The low-friction path for logging WODs: the athlete gets the workout as a PHOTO, hands the photo to
// any capable AI with the prompt from `WodTextImport.aiPrompt` ("Copy AI prompt"), pastes the AI's
// reply here, taps Analyze, checks the preview and saves — one or many WODs, with movements, the
// prescribed (RX) and actually-lifted loads all filled in. No field-by-field typing. Parsing is the
// pure `WodTextImport` in WhoopStore; this screen is just the paste box, preview and save.

struct WodImportView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    /// Called after a successful save so the list can refresh.
    let onSaved: () -> Void

    @State private var text = ""
    @State private var parsed: [WodLogRow] = []
    @State private var didParse = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .font(.callout)
                } header: {
                    Text("Paste WOD text")
                } footer: {
                    Text("One block per WOD; separate several with a line of “---”. Labels like Name, Movements, RX and Result are understood in English and Italian.")
                }

                Section {
                    Button { pasteFromClipboard() } label: {
                        Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button { copyAIPrompt() } label: {
                        Label("Copy AI prompt (for your photo)", systemImage: "sparkles")
                    }
                    Button { analyze() } label: {
                        Label("Analyze", systemImage: "wand.and.stars")
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if didParse {
                    if parsed.isEmpty {
                        Section {
                            Text("Couldn't find a WOD in that text. Check the format, or tap “Copy AI prompt” and let an AI convert your photo.")
                                .foregroundStyle(.secondary).font(.subheadline)
                        }
                    } else {
                        Section("Preview") {
                            ForEach(parsed) { w in WodPreviewRow(wod: w) }
                        }
                    }
                }
            }
            .navigationTitle("Import WODs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save all") { saveAll() }
                        .disabled(parsed.isEmpty || saving)
                }
            }
        }
    }

    private func analyze() {
        parsed = WodTextImport.parse(text)
        didParse = true
    }

    private func pasteFromClipboard() {
        if let s = UIPasteboard.general.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = s
            analyze()
        }
    }

    private func copyAIPrompt() {
        UIPasteboard.general.string = WodTextImport.aiPrompt
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
        }
        .padding(.vertical, 2)
    }
}

#endif
