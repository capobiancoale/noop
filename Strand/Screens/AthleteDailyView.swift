#if os(iOS)
import SwiftUI
import WhoopStore
import StrandAnalytics
import StrandDesign

private extension AthleteCheckInField {
    var title: String {
        switch self {
        case .energy: return "Energy"
        case .muscleFatigue: return "Muscle fatigue"
        case .stress: return "Perceived stress"
        case .sleepQuality: return "Perceived sleep quality"
        }
    }
    var choices: [String] {
        switch self {
        case .energy: return ["Very low", "Low", "Moderate", "High", "Very high"]
        case .muscleFatigue, .stress: return ["None", "Mild", "Moderate", "High", "Very high"]
        case .sleepQuality: return ["Very poor", "Poor", "Fair", "Good", "Very good"]
        }
    }
}

struct AthleteCheckInCard: View {
    @EnvironmentObject private var repo: Repository
    let day: String
    let recovery: Double?
    @State private var values: [AthleteCheckInField: Int] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var dirty = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Morning check-in").font(.headline)
                Text(day).font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView("Loading your journal") }
                else {
                    ForEach(AthleteCheckInField.allCases, id: \.self) { field in
                        VStack(alignment: .leading) {
                            Text(field.title).font(.subheadline)
                            Picker(field.title, selection: Binding(
                                get: { values[field] ?? 0 },
                                set: { value in
                                    if value == 0 { values.removeValue(forKey: field) } else { values[field] = value }
                                    dirty = true; message = nil
                                })) {
                                Text("Not recorded").tag(0)
                                ForEach(1...5, id: \.self) { value in
                                    Text("\(value) · \(field.choices[value - 1])").tag(value)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityLabel(field.title)
                        }
                    }
                    if let discrepancy {
                        Label(discrepancy, systemImage: "text.bubble")
                            .font(.subheadline)
                    }
                    Button(saving ? "Saving…" : "Save check-in") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || !dirty || failed)
                    if let message { Text(message).font(.caption).accessibilityAddTraits(.updatesFrequently) }
                    if failed { Button("Retry loading") { Task { await read() } } }
                    Text("Optional personal observations. This check-in is not a validated clinical questionnaire and does not change Charge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(saving)
        }
        .task { await read() }
    }

    private var discrepancy: String? {
        guard let recovery, let energy = values[.energy] else { return nil }
        if (recovery >= 67 && energy <= 2) || (recovery < 34 && energy >= 4) {
            return "Your energy and Charge point in different directions. Both are shown; neither overrides the other."
        }
        return nil
    }

    private func read() async {
        loading = true
        do {
            guard let store = await repo.storeHandle() else { throw CocoaError(.fileReadUnknown) }
            let rows = try await store.journalEntries(deviceId: Repository.journalDeviceId, from: day, to: day)
            var readValues: [AthleteCheckInField: Int] = [:]
            for field in AthleteCheckInField.allCases {
                if let v = rows.first(where: { $0.question == field.journalKey })?.numericValue,
                   v.isFinite, v == v.rounded(), (1...5).contains(v) { readValues[field] = Int(v) }
            }
            values = readValues; dirty = false; failed = false
            let stamps = rows.filter { $0.question.hasPrefix("noop.checkin.v1.") }.compactMap(\.notes)
            message = stamps.max().map { "Saved on device · " + $0 }
        } catch { failed = true; message = "Journal unavailable. Retry before editing." }
        loading = false
    }

    private func save() {
        saving = true
        Task {
            do {
                guard let store = await repo.storeHandle() else { throw CocoaError(.fileWriteUnknown) }
                try await store.saveAthleteCheckIn(day: day, values: values)
                dirty = false
                message = "Saved on device."
                NotificationCenter.default.post(name: .athleteJournalChanged, object: nil)
            } catch { message = "Not saved. Your answers are still here; please retry." }
            saving = false
        }
    }
}

extension Notification.Name {
    static let athleteJournalChanged = Notification.Name("noop.athleteJournalChanged")
}

struct AthleteReviewCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    let day: String
    @State private var journal: [JournalEntry] = []
    @State private var sessions: [WodLogRow] = []
    @State private var coverage: StrainScorer.Coverage?
    @State private var cardiovascularLoad: Double?
    @State private var sources: [String] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showEditor = false
    @State private var refresh = 0

    private var start: String { ReadinessEngine.dayKey(day, adding: -6) ?? day }
    private var week: [DailyMetric] { repo.days.filter { $0.day >= start && $0.day <= day } }
    private var selected: DailyMetric? { repo.days.first { $0.day == day } }
    private var previousStart: String { ReadinessEngine.dayKey(day, adding: -13) ?? day }
    private var previousSessions: [WodLogRow] { sessions.filter { $0.day >= previousStart && $0.day < start } }
    private var currentSessions: [WodLogRow] { sessions.filter { $0.day >= start && $0.day <= day } }
    private func average(_ values: [Double]) -> String {
        let valid = values.filter(\.isFinite)
        guard !valid.isEmpty else { return "Not recorded" }
        return String(format: "%.1f", valid.reduce(0, +) / Double(valid.count))
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("Understand your signals") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Charge · experimental estimate").font(.headline)
                        Text("The NOOP model combines HRV (55%), resting heart rate (20%), sleep (15%), breathing (5%) and skin temperature (5%). Available components are reweighted. These are model choices, not clinical validation. Imported scores use their provider's method.")
                        Text("Sources for this day: " + (sources.isEmpty ? "Unavailable" : sources.joined(separator: ", ")))
                        Text("Daily record: " + day + ". Per-score calculation timestamps and overnight signal coverage are not recorded in this cache.")
                        if selected?.recovery == nil {
                            Text("Charge unavailable: a usable recovery record or sufficient personal baseline is missing.")
                        }
                        if let c = coverage {
                            Text("Local HR coverage: \(Int(c.observedSeconds / 60)) min · gaps \(Int(c.gapSeconds / 60)) min · \(c.samples) samples")
                            if let ts = c.lastTimestamp {
                                Text("Latest local HR sample: " + Date(timeIntervalSince1970: Double(ts)).formatted(date: .abbreviated, time: .shortened))
                            }
                            Text("Coverage includes one estimated final sampling interval; gaps over 60 seconds are excluded. It does not describe imported score coverage.")
                        }
                        Text("Methods: " + StrainScorer.methodVersion + " · " + ReadinessEngine.methodVersion)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Your last 7 days").font(.headline)
                Text("\(start) – \(day)").font(.caption).foregroundStyle(.secondary)
                if !loaded { ProgressView() }
                if let error { Text(error).font(.caption) }
                Text("Logged sessions: \(currentSessions.count) · previous 7 days: \(previousSessions.count)")
                Text("Sleep: \(average(week.compactMap(\.totalSleepMin))) min/night · \(week.compactMap(\.totalSleepMin).count)/7 nights")
                Text("Historical Effort (composite): \(average(week.compactMap(\.strain))) /100 · \(week.compactMap(\.strain).count)/7 days")
                Text("Selected-day cardiovascular load: " + (cardiovascularLoad.map { String(format: "%.1f TRIMP", $0) } ?? "Unavailable — needs HR coverage, resting HR and maximum HR"))
                Text("Historical Effort may include estimated session-RPE contributions. The cardiovascular load above uses only recorded HR and is shown separately.")
                    .font(.caption).foregroundStyle(.secondary)
                let loads = currentSessions.compactMap { s -> Double? in
                    guard let r = s.rpe, r.isFinite, let duration = s.durationS, duration > 0 else { return nil }
                    return r * Double(duration) / 60
                }
                Text("Perceived load: \(loads.isEmpty ? "Not recorded" : String(format: "%.0f AU", loads.reduce(0, +))) · \(loads.count)/\(currentSessions.count) sessions with actual duration and RPE")
                let volumes = currentSessions.compactMap(\.recordedVolumeKg)
                Text("Recorded external volume: \(volumes.isEmpty ? "Not recorded" : String(format: "%.0f kg·reps", volumes.reduce(0, +)))")
                ForEach(AthleteCheckInField.allCases, id: \.self) { field in
                    let values = journal.filter { $0.question == field.journalKey }.compactMap(\.numericValue)
                    Text("\(field.title): \(average(values)) /5 · \(values.count)/7 days")
                }
                Text("These measures stay separate. Missing days are unknown, not rest days.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Log training") { showEditor = true }.buttonStyle(.borderedProminent)
                NavigationLink("Training history and comparable benchmarks") { WodLogView() }
                ForEach(currentSessions.prefix(3)) { session in
                    NavigationLink {
                        WodDetailView(wod: session) { refresh += 1 }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(session.title)
                            Text(session.day + " · " + (WodFormat.result(session) ?? "No result"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: "\(repo.refreshSeq)-\(refresh)") { await read() }
        .onReceive(NotificationCenter.default.publisher(for: .athleteJournalChanged)) { _ in refresh += 1 }
        .sheet(isPresented: $showEditor) {
            WodEditorView(existing: nil, initialDate: Self.date(for: day)) { refresh += 1 }
        }
    }

    private static func date(for day: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: day).flatMap { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: $0) }
    }

    private func read() async {
        do {
            guard let store = await repo.storeHandle() else { throw CocoaError(.fileReadUnknown) }
            journal = try await store.journalEntries(deviceId: Repository.journalDeviceId, from: start, to: day)
            sessions = try await store.allWods(limit: 10000).filter { $0.day >= previousStart && $0.day <= day }
            let resolved = await repo.resolvedSeries(key: "recovery", source: "my-whoop")
            sources = Array(Set(resolved.points.filter { $0.day == day }.map(\.source))).sorted()
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            if let date = f.date(from: day), let end = Calendar.current.date(byAdding: .day, value: 1, to: date) {
                let hr = await repo.hrSamples(from: Int(date.timeIntervalSince1970), to: Int(end.timeIntervalSince1970) - 1, limit: 200000)
                coverage = StrainScorer.coverage(hr)
                if let resting = selected?.restingHr, profile.hrMax > resting {
                    cardiovascularLoad = StrainScorer.trimp(hr, maxHR: Double(profile.hrMax), restingHR: Double(resting))
                } else { cardiovascularLoad = nil }
            }
            error = nil
        } catch { error = "Some records could not be loaded. Try opening this day again." }
        loaded = true
    }
}
#endif
