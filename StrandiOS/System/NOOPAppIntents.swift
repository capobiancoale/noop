#if os(iOS)
import Foundation
import AppIntents
import UIKit
import UniformTypeIdentifiers
import WhoopStore
import StrandImport

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
enum PendingIntents {
    enum Action: String { case markMoment, buzz }

    private static let key = "noop.pendingIntents"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Optional `at` is the invocation time, captured now and consumed on drain. Encoded into the
    /// stored string as "rawValue:epochSeconds" so the array stays a plain [String] (no schema
    /// migration; a legacy bare "markMoment" still decodes with a nil date).
    static func append(_ action: Action, at date: Date? = nil) {
        guard let d = defaults else { return }
        var list = d.stringArray(forKey: key) ?? []
        if let date { list.append("\(action.rawValue):\(date.timeIntervalSince1970)") }
        else { list.append(action.rawValue) }
        d.set(list, forKey: key)
    }

    static func drain() -> [(action: Action, date: Date?)] {
        guard let d = defaults else { return [] }
        let raw = d.stringArray(forKey: key) ?? []
        d.removeObject(forKey: key)
        return raw.compactMap { entry in
            // Guard `parts.first` rather than subscripting `parts[0]`: split(omittingEmptySubsequences:
            // true by default) returns an EMPTY array for an empty or ":"-leading entry, and indexing
            // [0] there is a fatal trap. This value comes from shared App Group defaults read untrusted,
            // so a corrupt/foreign entry must be skipped, not crash the app on foreground.
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let action = Action(rawValue: String(first)) else { return nil }
            let date = parts.count == 2 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return (action, date)
        }
    }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in NOOP.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
    }
}

/// Why the Databricks export could not run.
enum ExportForDatabricksError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable: return "Couldn't open the local store."
        }
    }
}

/// Writes the user's sport and sleep summaries as CSV files and returns them to the Shortcut, which uploads
/// them to Databricks itself: NOOP never talks to the network here and never sees the access token. Meant for
/// a daily personal automation (the last 14 days, so a corrected night or WOD is re-sent) plus one manual run
/// with `days = 0` for the whole history. The files are the fixed allowlist in `DatabricksCsv`: glucose,
/// insulin, nutrition, blood pressure, weight, mood and raw sensor streams are never part of them.
struct ExportForDatabricksIntent: AppIntent {
    static var title: LocalizedStringResource = "Export data for Databricks"
    static var description = IntentDescription("Writes your sleep, recovery, workout, WOD and heart-rate zone summaries as CSV files and hands them to the Shortcut. Glucose, insulin, nutrition, blood pressure, weight, mood and raw sensor data are never included.")
    static var openAppWhenRun = false

    /// How many days back to export, today included. 0 exports the whole history.
    @Parameter(title: "Days", default: 14)
    var days: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let window = max(0, min(days, 36_500))
        let store = try await Self.openStore()
        let deviceId = await Self.canonicalDeviceId()
        let urls = try await DatabricksExport.writeFiles(store: store, deviceId: deviceId,
                                                         maxHR: ProfileStore.storedHRMax(), days: window)
        let files = urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: .commaSeparatedText) }
        return .result(value: files)
    }

    /// The running app's own store handle when NOOP is alive; otherwise a handle on the same database file
    /// (WAL mode with a busy timeout is what lets the app's BLE collector and the read model share it).
    static func openStore() async throws -> WhoopStore {
        if let live = await liveStore() { return live }
        do {
            return try await WhoopStore(path: StorePaths.defaultDatabasePath())
        } catch {
            throw ExportForDatabricksError.storeUnavailable
        }
    }

    @MainActor
    private static func liveStore() async -> WhoopStore? {
        guard let repo = AppModel.shared?.repo else { return nil }
        return await repo.storeHandle()
    }

    /// The canonical imported/computed id the app keeps history under (see `Repository.whoopSource`).
    @MainActor
    static func canonicalDeviceId() -> String { Repository.whoopSource }
}

/// Why the Databricks upload stopped, worded as what the user has to fix.
enum UploadToDatabricksError: Error, CustomLocalizedStringResourceConvertible {
    case invalidAddress
    case invalidCatalog
    case missingToken
    case unauthorized(Int)
    case notFound
    case http(Int)
    case network(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidAddress:
            return "The workspace address must be your Databricks address, like https://dbc-….cloud.databricks.com."
        case .invalidCatalog:
            return "The catalog name can only contain letters, digits and underscores."
        case .missingToken:
            return "Paste your Databricks access token."
        case .unauthorized(let code):
            return "Databricks refused the token (HTTP \(code)). Check that it was pasted whole and has not expired."
        case .notFound:
            return "Databricks has no volume at that path (HTTP 404). Check the catalog name and that the noop schema and raw volume exist."
        case .http(let code):
            return "Databricks answered with an error (HTTP \(code)). Try again later."
        case .network(let message):
            return "Couldn't reach Databricks: \(message)"
        }
    }
}

/// Exports the same sport and sleep CSVs as `ExportForDatabricksIntent` and uploads them itself to the user's
/// own Unity Catalog volume (`<catalog>/noop/raw`) with the Files API, so the Shortcut is this one action plus
/// a daily automation. Only a Databricks workspace address is accepted (`DatabricksUpload.workspaceOrigin`),
/// the token is used for this run's requests only (kept by the Shortcut, never stored or logged by NOOP), and
/// the files are the fixed allowlist in `DatabricksCsv`: no glucose, insulin or raw sensor data.
struct UploadToDatabricksIntent: AppIntent {
    static var title: LocalizedStringResource = "Upload to Databricks"
    static var description = IntentDescription("Exports your sleep, recovery, workout, WOD and heart-rate zone summaries and uploads them to your own Databricks workspace. NOOP sends them only to the Databricks address you enter and does not keep the token. Glucose, insulin, nutrition, blood pressure, weight, mood and raw sensor data are never included.")
    static var openAppWhenRun = false

    @Parameter(title: "Workspace address",
               inputOptions: String.IntentInputOptions(keyboardType: .URL, capitalizationType: .none,
                                                       multiline: false, autocorrect: false,
                                                       smartQuotes: false, smartDashes: false))
    var workspace: String

    @Parameter(title: "Catalog", default: "noop_uploads",
               inputOptions: String.IntentInputOptions(keyboardType: .asciiCapable, capitalizationType: .none,
                                                       multiline: false, autocorrect: false,
                                                       smartQuotes: false, smartDashes: false))
    var catalog: String

    @Parameter(title: "Access token",
               inputOptions: String.IntentInputOptions(keyboardType: .asciiCapable, capitalizationType: .none,
                                                       multiline: false, autocorrect: false,
                                                       smartQuotes: false, smartDashes: false))
    var token: String

    /// How many days back to upload, today included. 0 uploads the whole history.
    @Parameter(title: "Days", default: 14)
    var days: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let origin = DatabricksUpload.workspaceOrigin(workspace) else { throw UploadToDatabricksError.invalidAddress }
        let catalogName = catalog.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DatabricksUpload.isValidCatalog(catalogName) else { throw UploadToDatabricksError.invalidCatalog }
        guard let bearer = DatabricksUpload.cleanToken(token) else { throw UploadToDatabricksError.missingToken }

        let window = max(0, min(days, 36_500))
        let store = try await ExportForDatabricksIntent.openStore()
        let deviceId = await ExportForDatabricksIntent.canonicalDeviceId()
        let files = try await DatabricksExport.writeFiles(store: store, deviceId: deviceId,
                                                          maxHR: ProfileStore.storedHRMax(), days: window)
        // The CSVs are copies made for this upload; drop their folder whatever happens below.
        defer { if let folder = files.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) } }

        for file in files {
            guard let target = DatabricksUpload.fileURL(origin: origin, catalog: catalogName,
                                                        fileName: file.lastPathComponent) else {
                throw UploadToDatabricksError.invalidCatalog
            }
            let body = try Data(contentsOf: file)
            let response: URLResponse
            do {
                response = try await URLSession.shared.data(for: DatabricksUpload.request(url: target, token: bearer,
                                                                                          body: body)).1
            } catch {
                throw UploadToDatabricksError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch DatabricksUpload.failure(forStatus: status) {
            case nil: continue
            case .unauthorized(let code)?: throw UploadToDatabricksError.unauthorized(code)
            case .notFound?: throw UploadToDatabricksError.notFound
            case .http(let code)?: throw UploadToDatabricksError.http(code)
            }
        }
        return .result(dialog: "Uploaded \(files.count) files to Databricks.")
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
        AppShortcut(intent: ExportForDatabricksIntent(),
                    phrases: ["Export my \(.applicationName) data for Databricks"],
                    shortTitle: "Export for Databricks",
                    systemImageName: "square.and.arrow.up")
    }
}
#endif
