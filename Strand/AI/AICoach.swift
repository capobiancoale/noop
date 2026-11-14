import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question - only a short text summary of your metrics goes to the provider you pick."

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// UserDefaults key recording which provider the stored API key belongs to, so one provider's key
    /// is never sent to another provider's endpoint (above all the arbitrary user-typed Custom URL).
    private static let ownerKey = "ai.keyProvider"

    /// The provider the stored key was saved for, or nil for a legacy key saved before this tracking.
    static var ownerProvider: String? { UserDefaults.standard.string(forKey: ownerKey) }

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear.
    /// Returns true once the key is in the Keychain (or was cleared); false if the Keychain write
    /// failed, in which case the owner marker is left untouched so it never points at a key that
    /// isn't actually stored (#872). The live `read()`/`hasKey` gating already reads the real
    /// Keychain, so this is defensive tidying of the discarded write result, not a behaviour change.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(owner, forKey: ownerKey)
        return true
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {
    case noKey
    case emptyQuestion
    case badKey
    case rateLimited
    case server(Int, String)
    case network(String)
    case decode
    case keySaveFailed

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []
    @Published var sending = false
    /// True while `connectCustom()` is probing the server (drives the Connect button's progress state).
    @Published var connecting = false
    @Published var errorText: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    /// THIRD opt-in (4b): also add DAILY glucose summaries (average, time in range, lows) from Apple Health
    /// for the last 14 days. OFF by default and gated behind `dataConsent` too. Never single readings,
    /// never insulin or carbohydrate amounts.
    @Published var includeGlucose: Bool {
        didSet { UserDefaults.standard.set(includeGlucose, forKey: Self.glucoseKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    private static let glucoseKey = "ai.includeGlucose"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    HRV, resting heart rate) and recent workouts. Charge is the daily recovery/readiness score, effort \
    is the daily cardiovascular load score, and rest is the nightly sleep-quality score. \
    The context also carries a plan for today computed by the app, the user's goal, their logged CrossFit \
    WODs with loads, and their strength bests: start from the plan and explain it, and if you disagree \
    with it say why. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose, never give insulin doses or changes to diabetes therapy \
    settings; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    /// The app's language code for the "Reply in ..." line.
    private static var appLanguageCode: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The no-consent note, still ending with the safety and language lines.
    func noConsentContext() -> String {
        [noConsentNote, CoachContext.safetyLine, CoachContext.languageLine(languageCode: Self.appLanguageCode)]
            .joined(separator: "\n\n")
    }

    init(repo: Repository, session: URLSession = .shared) {
        self.repo = repo
        self.session = session

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        self.includeGlucose = UserDefaults.standard.bool(forKey: Self.glucoseKey)
    }

    // MARK: Key management

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for, never Bearer one provider's
            // key (e.g. a cloud OpenAI/Anthropic secret) to another provider's endpoint, above all the
            // arbitrary user-typed Custom URL. A legacy key with no recorded owner is assumed to belong
            // to a cloud provider, so it is never auto-sent to Custom.
            let owner = AIKeyStore.ownerProvider
            if owner == provider.rawValue { return k }
            if owner == nil && provider != .custom { return k }
        }
        return provider == .custom ? "" : nil
    }

    /// Candidate base URLs to try for a user-typed Custom server address. Pure. Trims, adds `http://`
    /// when there is no scheme, strips trailing slashes, returns the address as typed first and, when its
    /// path does not already end in `/v1`, the same address + `/v1` second (Ollama serves the
    /// OpenAI-compatible API under `/v1`). Empty input gives no candidates.
    nonisolated static func customURLCandidates(_ raw: String) -> [String] {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return [] }
        if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
            url = "http://" + url
        }
        while url.hasSuffix("/") { url.removeLast() }
        if url.lowercased().hasSuffix("/v1") { return [url] }
        return [url, url + "/v1"]
    }

    /// Practical, localized hint shown when no candidate address answered.
    private static func customUnreachableMessage(_ url: String) -> String {
        String(localized: "Couldn't reach the server at \(url). Check that the Mac is on and awake, that it is on the same Wi-Fi as this iPhone, and that Ollama is running. Also make sure NOOP is allowed under Settings > Privacy & Security > Local Network.")
    }

    /// One `GET <base>/models` against the current Custom base URL, through the DEBUG test seam when set.
    private func fetchCustomModelIDs(key: String) async throws -> [String] {
        #if DEBUG
        if let override = fetchModelsOverride {
            return try await override(.custom, key)
        }
        #endif
        return try await AIProvider.custom.client.fetchModels(key: key, session: session)
    }

    /// Commit the Custom (local) provider only once the server answers. Tries each candidate address
    /// (see `customURLCandidates`) with `GET /models`; the one that answers is stored in `customBaseURL`.
    /// A 404/405/501 on `/models` means reachable-but-no-model-list and still counts as connected (a later
    /// candidate that returns a real list wins over it). On failure the user's typed text is restored,
    /// `customConnected` stays false and `errorText` explains what to check.
    func connectCustom() async {
        guard !connecting else { return }
        let original = customBaseURL
        let candidates = Self.customURLCandidates(original)
        guard !candidates.isEmpty else { return }
        connecting = true
        errorText = nil
        defer { connecting = false }

        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        var reachableWithoutList: String?
        var ids: [String]?
        var answered: String?
        for candidate in candidates {
            // `AIProvider.customURL(path:)` reads the base from UserDefaults, so set it before each try.
            customBaseURL = candidate
            do {
                ids = try await fetchCustomModelIDs(key: key)
                answered = candidate
                break
            } catch AICoachError.server(let code, _) where [404, 405, 501].contains(code) {
                if reachableWithoutList == nil { reachableWithoutList = candidate }
            } catch let e as AICoachError {
                switch e {
                case .badKey, .rateLimited:
                    // The server answered but refused us: another address will not help.
                    customBaseURL = original
                    errorText = e.errorDescription
                    return
                default:
                    continue
                }
            } catch {
                continue
            }
        }

        if answered == nil, let fallback = reachableWithoutList {
            answered = fallback
        }
        guard let chosen = answered else {
            customBaseURL = original
            errorText = Self.customUnreachableMessage(candidates[0])
            return
        }
        customBaseURL = chosen
        guard provider == .custom else { return }
        customConnected = true

        if let ids, !ids.isEmpty {
            let merged = Set(ids).sorted()
            availableModels = merged
            let current = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if merged.contains("noop-coach"), current.isEmpty || !merged.contains(current) {
                model = "noop-coach"
            } else if current.isEmpty, let first = merged.first {
                model = first
            } else if !current.isEmpty, !merged.contains(current) {
                availableModels.insert(current, at: 0)
            }
        }
    }

    /// Disconnect entirely: forget any stored key and un-commit the Custom provider. The base URL is
    /// kept so reconnecting pre-fills it.
    func disconnect() {
        AIKeyStore.clear()
        customConnected = false
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872), and skip the
    /// model refresh (it would only hit `.noKey`).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        errorText = nil
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // Pull the user's ACTUAL current models from the provider so the picker is never stale.
        Task { await refreshModels() }
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            return
        }
    }

    // MARK: Sending

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        errorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        sending = true
        defer { sending = false }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentContext()
        let wire = wireMessages(context: context)

        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: .assistant, text: clean.isEmpty ? "(no reply)" : clean))
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false }

        let context = await buildFullContext()
        let instruction = """
        Based on the data above, give me TODAY'S coaching brief in four short parts: \
        (1) my readiness in one line, citing Charge, HRV and sleep; \
        (2) today's training, following the plan; \
        (3) what to eat today, using the plan's ranges; \
        (4) one thing to work on, taken from the plan's focus list. Be punchy and motivating.
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: String(localized: "Today's brief") + "\n\n" + clean))
            }
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Rough ceiling for the whole context (about 2,500 tokens); see `assembleContext`.
    nonisolated static let contextCharLimit = 10_000

    /// The blocks of the full context, already formatted. nil / empty parts are skipped on assembly.
    struct ContextParts {
        /// Today line, profile, plan, last night, load, recent days (in this order, nil already dropped).
        var head: [String] = []
        var workouts: String?
        var wods: String?
        /// The same WOD block limited to the 3 newest.
        var wodsShort: String?
        var strength: String?
        var stress: String?
        var signals: String?
        var glucose: String?
        /// Safety line, then language line: never dropped.
        var tail: [String] = []
    }

    /// Joins the blocks in order with blank lines. When the result exceeds `limit` characters, drops, one
    /// step at a time until it fits: strength, on-device signals, workouts, WODs beyond the first 3. The plan
    /// (in `head`) and the safety and language lines (in `tail`) are never dropped.
    nonisolated static func assembleContext(_ p: ContextParts, limit: Int = contextCharLimit) -> String {
        func build(_ step: Int) -> String {
            var blocks: [String?] = p.head.map { Optional($0) }
            blocks.append(step >= 3 ? nil : p.workouts)
            blocks.append(step >= 4 ? p.wodsShort : p.wods)
            blocks.append(step >= 1 ? nil : p.strength)
            blocks.append(p.stress)
            blocks.append(step >= 2 ? nil : p.signals)
            blocks.append(p.glucose)
            blocks.append(contentsOf: p.tail.map { Optional($0) })
            return blocks.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        var out = build(0)
        var step = 0
        while out.count > limit && step < 4 {
            step += 1
            out = build(step)
        }
        return out
    }

    /// Full data context, in this order: today, profile, plan, last night, load, recent days, workouts, WODs,
    /// strength, stress, (opt-in) on-device signals, (opt-in) glucose, safety, language. Used when the user
    /// has granted data access.
    func buildFullContext() async -> String {
        let snap = await DayPlanBuilder.snapshot(repo: repo)
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let wods = await repo.allWods()

        var parts = ContextParts()

        // Today, in English from fixed POSIX formatters (the text is for the model).
        let now = Date()
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "en_US_POSIX")
        weekdayFmt.dateFormat = "EEEE"
        parts.head.append(CoachContext.todayLine(
            day: Repository.localDayKey(now), weekday: weekdayFmt.string(from: now),
            localTime: Self.clockString(now), chargeScored: snap.todayRow?.recovery != nil))

        let profile = DayPlanBuilder.ProfileValues.stored()
        if let line = CoachContext.profileLine(
            age: profile.age, sex: profile.sex, weightKg: profile.weightKg, heightCm: profile.heightCm,
            maxHR: ProfileStore.storedHRMax(), goal: profile.goal) {
            parts.head.append(line)
        }
        parts.head.append(CoachContext.planBlock(snap.plan))
        let bedtime = snap.lastNight.map { Self.clockString(Date(timeIntervalSince1970: Double($0.effectiveStartTs))) }
        let wake = snap.lastNight.map { Self.clockString(Date(timeIntervalSince1970: Double($0.endTs))) }
        if let block = CoachContext.lastNightBlock(
            day: snap.todayRow, bedtime: bedtime, wake: wake, restScore: snap.restScore,
            needMin: snap.sleepNeedMin, debtMin: snap.sleepDebtMin) {
            parts.head.append(block)
        }
        if let line = CoachContext.loadLine(snap.load) { parts.head.append(line) }
        parts.head.append(buildContext(restByDay: restByDay))

        parts.workouts = await recentWorkoutsBlock()
        parts.wods = CoachContext.wodBlock(wods, today: snap.todayKey)
        parts.wodsShort = CoachContext.wodBlock(wods, today: snap.todayKey, limit: 3)

        let strengthLines = StrengthProgress.summaryLines(StrengthProgress.movements(from: wods), today: snap.todayKey)
        if !strengthLines.isEmpty {
            parts.strength = (["STRENGTH (best and latest loads, estimated 1RM is an estimate):"]
                              + strengthLines.map { "- " + $0 }).joined(separator: "\n")
        }

        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Same consent + text-only channel as the HRV/RHR summary: a derived number,
        // never raw R-R egress. Omitted when there aren't enough clean beats yet.
        parts.stress = await stressIndexLine()
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { parts.signals = block }
        }
        if includeGlucose { parts.glucose = await glucoseBlock(todayKey: snap.todayKey) }

        parts.tail = [CoachContext.safetyLine, CoachContext.languageLine(languageCode: Self.appLanguageCode)]
        return Self.assembleContext(parts)
    }

    /// "HH:mm" in the phone's local time zone, fixed POSIX digits.
    private static func clockString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Glucose (opt-in, daily summaries only)

    /// The keys read, in the order they are written. Only daily summaries, never single readings.
    nonisolated static let glucoseKeys = [
        "glucose_avg", "glucose_tir", "glucose_tbr", "glucose_tar", "glucose_cv",
        "glucose_hypos", "glucose_overnight_min", "glucose_postex_min",
    ]
    nonisolated static let glucoseWindowDays = 14

    /// True when Apple Health holds a glucose_avg point in the last 14 days (decides whether the
    /// "Also share my glucose summary" card is shown).
    func hasGlucoseData() async -> Bool {
        let pts = await repo.series(key: "glucose_avg", source: Repository.appleHealthSource,
                                    days: Self.glucoseWindowDays)
        return !pts.isEmpty
    }

    /// Reads the daily summary series (14 days) and formats them; nil when no series has data.
    func glucoseBlock(todayKey: String) async -> String? {
        var series: [String: [(day: String, value: Double)]] = [:]
        for key in Self.glucoseKeys {
            series[key] = await repo.series(key: key, source: Repository.appleHealthSource,
                                            days: Self.glucoseWindowDays)
        }
        var recent: Set<String> = [todayKey]
        if let y = Self.previousDayKey(todayKey) { recent.insert(y) }
        return Self.glucoseSummary(series: series, recentDays: recent)
    }

    /// "yyyy-MM-dd" of the day before `key`, nil when unparseable.
    nonisolated static func previousDayKey(_ key: String) -> String? {
        let p = key.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              let prev = cal.date(byAdding: .day, value: -1, to: date) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: prev)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Pure formatter of the glucose block. Per key: the mean over the series (the sum for lows) and the
    /// latest value when its day is in `recentDays` (today and yesterday). mg/dL for glucose values, % for the
    /// time-in-range family and the variability. nil when no key has a finite point. Background only: no
    /// single readings, no insulin or carbohydrate amounts.
    nonisolated static func glucoseSummary(series: [String: [(day: String, value: Double)]],
                                           recentDays: Set<String>) -> String? {
        func num(_ x: Double) -> String { String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), x) }
        // key -> (label, unit)
        let spec: [String: (label: String, unit: String)] = [
            "glucose_avg": ("average glucose", " mg/dL"),
            "glucose_tir": ("time in range", "%"),
            "glucose_tbr": ("time below range", "%"),
            "glucose_tar": ("time above range", "%"),
            "glucose_cv": ("variability (CV)", "%"),
            "glucose_hypos": ("low events", ""),
            "glucose_overnight_min": ("lowest overnight glucose", " mg/dL"),
            "glucose_postex_min": ("lowest glucose after exercise", " mg/dL"),
        ]
        var lines: [String] = []
        for key in glucoseKeys {
            guard let info = spec[key] else { continue }
            let pts = (series[key] ?? []).filter { $0.value.isFinite }
            guard !pts.isEmpty else { continue }
            let latest = pts.sorted { $0.day < $1.day }.last
            var line: String
            if key == "glucose_hypos" {
                line = "- \(info.label): \(num(pts.reduce(0) { $0 + $1.value })) in total over \(pts.count) days with data"
            } else {
                let mean = pts.reduce(0) { $0 + $1.value } / Double(pts.count)
                line = "- \(info.label): mean \(num(mean))\(info.unit) over \(pts.count) days"
            }
            if let l = latest, recentDays.contains(l.day) {
                line += ", latest \(num(l.value))\(info.unit) (\(l.day))"
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return (["GLUCOSE, daily summaries from Apple Health, last 14 days (background only):"] + lines
                + ["Glucose is background only: never give insulin or carbohydrate amounts from it."])
            .joined(separator: "\n")
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index over TODAY's R-R, read
    /// via the store exactly as `StressView` does (`storeHandle()` → `rrIntervals(deviceId:from:to:)`),
    /// then summarised to a single number with `StressIndex.stressIndex(rr:)`. Returns nil when the
    /// store is unavailable or there are too few clean beats (the histogram needs >= 20), so the line is
    /// simply absent, never a fabricated value. Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        guard let store = await repo.storeHandle() else { return nil }
        let rr = (try? await store.rrIntervals(
            deviceId: repo.deviceId, from: from, to: to, limit: 200_000)) ?? []
        guard let si = StressIndex.stressIndex(rr: rr) else { return nil }
        return Self.stressIndexSummary(si: si)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        for e in entries where e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key, locale: Locale(identifier: "en_US_POSIX"))) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Dispatch to the user's chosen provider client.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        try await provider.client.send(
            key: key,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            session: session
        )
    }

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window, the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    private static let maxHistoryMessages = 10
    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        return [messages[firstUser]] + Array(messages[recentStart...])
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in windowedMessages() {
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String { buildContext(restByDay: [:]) }

    /// Same summary, with each day's Rest score (0-100, from the "sleep_performance" series, keyed by day)
    /// next to its sleep hours. A day with no score simply has no "rest" part.
    func buildContext(restByDay: [String: Double]) -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append("Recent days (newest first): charge 0-100, effort 0-100, sleep in hours, rest = sleep score 0-100, HRV in ms, RHR in bpm:")
        for d in recent {
            lines.append("  " + CoachContext.dayLine(d, restScore: restByDay[d.day]))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM { parts.append("\(String(format: "%.1f", dist / 1000)) km") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
