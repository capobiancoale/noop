#if os(iOS)
import SwiftUI
import StrandImport
import WhoopStore

// MARK: - WOD editor (create / edit)
//
// A plain SwiftUI Form to log or edit one WOD: type, name, date, format, optional time cap, a dynamic
// list of movements (name + reps + load), the result on the WOD's own scale, RPE and notes. Builds a
// `WodLogRow` and saves it through `Repository.saveWod`. Kept deliberately native (Form) so it is
// robust and familiar; the surrounding app chrome comes from the pushing/ presenting screen.

struct WodEditorView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The row being edited, or nil to create a new one.
    let existing: WodLogRow?
    /// Called after a successful save or delete so the list can refresh.
    let onSaved: () -> Void

    /// Every WOD is logged with its session's start and end. `initialDate` / `initialEnd` set a new WOD's
    /// (Today: when its workout started and ended); without them a new WOD is the hour up to now. An edit
    /// keeps the WOD's own times.
    init(existing: WodLogRow?, initialDate: Date? = nil, initialEnd: Date? = nil, onSaved: @escaping () -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        if existing == nil, let initialDate {
            _date = State(initialValue: initialDate)
            _endTime = State(initialValue: initialEnd ?? initialDate.addingTimeInterval(Self.defaultSessionSeconds))
        }
    }

    // Editable movement row (strings for the numeric fields; parsed on save). `reps` accepts a plain
    // count or a scheme like "21-15-9"; `weight` is my load, `rxWeight` the prescribed (RX) load.
    private struct EditMovement: Identifiable {
        let id = UUID()
        var name = ""
        var reps = ""
        var done = ""
        var weight = ""
        var rxWeight = ""
    }

    @State private var type = "CrossFit"
    @State private var title = ""
    /// The session's start; `endTime` supplies its end's time of day (see `sessionEnd`).
    @State private var date = Date().addingTimeInterval(-WodEditorView.defaultSessionSeconds)
    @State private var endTime = Date()
    @State private var format = "For Time"
    @State private var timeCapMin = ""
    @State private var rxMode = 0   // 0 = unset, 1 = RX, 2 = Scaled
    @State private var movements: [EditMovement] = [EditMovement()]
    @State private var resultKind: WodResultKind = .time
    @State private var resMin = ""
    @State private var resSec = ""
    @State private var resRounds = ""
    @State private var resReps = ""
    @State private var resWeight = ""
    @State private var rpe = 0.0
    @State private var notes = ""

    private let types = ["CrossFit", "Weightlifting", "Hyrox", "Running", "Rowing", "Other"]
    private let formats = ["For Time", "AMRAP", "EMOM", "Strength", "Intervals", "Other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    Picker("Type", selection: $type) { ForEach(types, id: \.self) { Text($0) } }
                    TextField("Name (e.g. Fran, Back Squat 5×5)", text: $title)
                    DatePicker("Session start", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Ends at", selection: $endTime, displayedComponents: .hourAndMinute)
                    if sessionTooLong {
                        Text("A session can last at most 4 hours.")
                            .font(.footnote).foregroundStyle(.red)
                    } else {
                        Text("Heart rate, zones and Effort read the whole session, warm-up and skill included. Rate the RPE for the whole session.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Format", selection: $format) { ForEach(formats, id: \.self) { Text($0) } }
                    HStack {
                        Text("Time cap (min)")
                        Spacer()
                        TextField("—", text: $timeCapMin)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("As prescribed?").font(.caption).foregroundStyle(.secondary)
                        Picker("RX / Scaled", selection: $rxMode) {
                            Text("—").tag(0)
                            Text("RX").tag(1)
                            Text("Scaled").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Movements") {
                    ForEach($movements) { $m in
                        VStack(spacing: 6) {
                            TextField("Movement (e.g. Thruster, Pull-up)", text: $m.name)
                            HStack(spacing: 8) {
                                TextField("Reps / scheme", text: $m.reps)
                                Divider()
                                TextField("Reps done", text: $m.done).keyboardType(.numberPad)
                            }
                            .font(.subheadline)
                            HStack(spacing: 8) {
                                TextField("My kg", text: $m.weight).keyboardType(.decimalPad)
                                Divider()
                                TextField("RX kg", text: $m.rxWeight).keyboardType(.decimalPad)
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { movements.remove(atOffsets: $0) }
                    Button { movements.append(EditMovement()) } label: {
                        Label("Add movement", systemImage: "plus")
                    }
                }

                Section("Result") {
                    Picker("Score", selection: $resultKind) {
                        Text("Duration").tag(WodResultKind.time)
                        Text("Rounds + reps").tag(WodResultKind.roundsReps)
                        Text("Reps").tag(WodResultKind.reps)
                        Text("Weight").tag(WodResultKind.weight)
                        Text("None").tag(WodResultKind.none)
                    }
                    resultFields
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("RPE")
                            Spacer()
                            Text(rpe > 0 ? String(Int(rpe)) : "—").foregroundStyle(.secondary)
                        }
                        Slider(value: $rpe, in: 0...10, step: 1)
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }

                if existing != nil {
                    Section {
                        Button("Delete WOD", role: .destructive) {
                            if let id = existing?.id {
                                Task { await repo.deleteWod(id: id); onSaved() }
                            }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Log WOD" : "Edit WOD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || sessionTooLong)
                }
            }
            .onAppear { if let e = existing { prefill(e) } }
        }
    }
    /// The result inputs for the selected scoring kind.
    @ViewBuilder private var resultFields: some View {
        switch resultKind {
        case .time:
            HStack {
                Text("Duration")
                Spacer()
                TextField("min", text: $resMin).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 54)
                Text(":")
                TextField("sec", text: $resSec).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 54)
            }
        case .roundsReps:
            HStack {
                Text("Rounds")
                TextField("0", text: $resRounds).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                Text("+ reps")
                TextField("0", text: $resReps).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
        case .reps:
            HStack {
                Text("Total reps")
                Spacer()
                TextField("0", text: $resReps).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
            }
        case .weight:
            HStack {
                Text("Weight (kg)")
                Spacer()
                TextField("0", text: $resWeight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: Session end

    /// The session's end: the picked time on the start's day, or the next day when that isn't after the start
    /// (a session past midnight).
    private var sessionEnd: Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: endTime)
        var end = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: date) ?? endTime
        if end <= date { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    /// A session's length when nothing says otherwise: an hour, a typical class.
    private static let defaultSessionSeconds = 3_600.0
    /// The longest span read as one session (`WodTimeWindow` ignores a longer one).
    private static let maxSessionSeconds = WodTimeWindow.maxRecordedMinutes * 60

    private var sessionTooLong: Bool { sessionEnd.timeIntervalSince(date) > Self.maxSessionSeconds }

    // MARK: Prefill (edit) + save

    private func prefill(_ e: WodLogRow) {
        type = e.type
        title = e.title
        let start = Date(timeIntervalSince1970: TimeInterval(e.ts))
        date = start
        // A WOD logged before sessions had an end (or imported) starts with an hour, to adjust.
        endTime = e.sessionSpan.map { Date(timeIntervalSince1970: TimeInterval($0.end)) }
            ?? start.addingTimeInterval(Self.defaultSessionSeconds)
        format = e.format ?? "For Time"
        timeCapMin = e.timeCapS.map { String($0 / 60) } ?? ""
        rxMode = e.rx == nil ? 0 : (e.rx! ? 1 : 2)
        movements = e.movements.isEmpty ? [EditMovement()] : e.movements.map {
            var m = EditMovement(); m.name = $0.name
            m.reps = $0.scheme ?? $0.reps.map(String.init) ?? ""
            m.done = $0.repsDone.map(String.init) ?? ""
            m.weight = $0.weightKg.map(WodFormat.trimmed) ?? ""
            m.rxWeight = $0.rxWeightKg.map(WodFormat.trimmed) ?? ""
            return m
        }
        resultKind = e.resultKind
        if let s = e.resultSeconds { resMin = String(s / 60); resSec = String(s % 60) }
        resRounds = e.resultRounds.map(String.init) ?? ""
        resReps = e.resultReps.map(String.init) ?? ""
        resWeight = e.resultWeightKg.map(WodFormat.trimmed) ?? ""
        rpe = e.rpe ?? 0
        notes = e.notes ?? ""
    }

    private func save() {
        let ts = Int(date.timeIntervalSince1970)
        let movs: [WodMovement] = movements.compactMap { m in
            let n = m.name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            let repsText = m.reps.trimmingCharacters(in: .whitespaces)
            let repsInt = Int(repsText)
            let scheme = (repsInt == nil && !repsText.isEmpty) ? repsText : nil
            return WodMovement(name: n,
                               reps: repsInt,
                               scheme: scheme,
                               repsDone: Int(m.done.trimmingCharacters(in: .whitespaces)),
                               weightKg: parseDouble(m.weight),
                               rxWeightKg: parseDouble(m.rxWeight))
        }
        let row = WodLogRow(
            id: existing?.id ?? UUID().uuidString,
            ts: ts,
            day: Self.dayKey.string(from: date),
            type: type,
            title: title.trimmingCharacters(in: .whitespaces),
            format: format,
            timeCapS: Int(timeCapMin.trimmingCharacters(in: .whitespaces)).map { $0 * 60 },
            resultKind: resultKind,
            resultSeconds: resultKind == .time ? ((Int(resMin) ?? 0) * 60 + (Int(resSec) ?? 0)) : nil,
            resultRounds: resultKind == .roundsReps ? Int(resRounds) : nil,
            resultReps: (resultKind == .roundsReps || resultKind == .reps) ? Int(resReps) : nil,
            resultWeightKg: resultKind == .weight ? parseDouble(resWeight) : nil,
            rpe: rpe > 0 ? rpe : nil,
            rx: rxMode == 0 ? nil : (rxMode == 1),
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes,
            movements: movs,
            createdTs: existing?.createdTs ?? Int(Date().timeIntervalSince1970),
            endTs: Int(sessionEnd.timeIntervalSince1970)
        )
        Task { await repo.saveWod(row); onSaved() }
        dismiss()
    }

    /// Parse a weight allowing a comma decimal separator (Italian locale). Blank → nil.
    private func parseDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return t.isEmpty ? nil : Double(t)
    }

    /// Canonical yyyy-MM-dd (local) day key, matching the store's day contract.
    private static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
}

#endif
