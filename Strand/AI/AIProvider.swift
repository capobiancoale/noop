import Foundation

// MARK: - Provider enum

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini:    return "Google Gemini"
        case .custom:    return "Custom (OpenAI-compatible)"
        }
    }

    /// The segment label in the provider picker: the four segments share one phone-width row, so "Google
    /// Gemini" and "Custom (OpenAI-compatible)" were cut to "Google G…" / "Custom (…". The full name still
    /// heads the status lines; a custom endpoint says "Custom" (translated, it is not a product name).
    var shortName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini:    return "Gemini"
        case .custom:    return String(localized: "Custom")
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini:    return "gemini-2.5-flash"
        case .custom:    return ""   // the user picks the model their server serves
        }
    }

    /// Models offered in the picker. A "Custom…" path in the UI lets the user pick any id beyond
    /// these, and `refreshModels()` can merge the provider's live list.
    var modelOptions: [String] {
        switch self {
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]
        case .anthropic:
            return [
                "claude-opus-4-8",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-3-7-sonnet-latest",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest"
            ]
        case .gemini:
            return [
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "gemini-2.5-flash-lite",
                "gemini-2.0-flash"
            ]
        case .custom:
            return []   // populated from the server's /models (refreshModels) or typed in
        }
    }

    var endpoint: URL {
        switch self {
        case .openAI:    return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .custom:    return AIProvider.customURL(path: "/chat/completions")
        }
    }

    var modelsEndpoint: URL {
        switch self {
        case .openAI:    return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .custom:    return AIProvider.customURL(path: "/models")
        }
    }

    var client: any AIProviderClient {
        switch self {
        case .openAI:    return OpenAIClient()
        case .anthropic: return AnthropicClient()
        case .gemini:    return GeminiClient()
        case .custom:    return CustomClient()
        }
    }

    // MARK: - Custom (OpenAI-compatible) base URL

    /// UserDefaults key for the Custom provider's base URL (e.g. a local LLM server such as Ollama /
    /// LM Studio / llama.cpp: `http://localhost:11434/v1`). `AICoachEngine` exposes it for editing.
    static let customBaseURLKey = "ai.customBaseURL"

    /// The user-set Custom base URL, trimmed.
    static var customBaseURL: String {
        (UserDefaults.standard.string(forKey: customBaseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a Custom endpoint by appending `path` to the user's base URL (trailing slashes tolerated).
    /// Falls back to a loopback placeholder when unset — the request then fails with a clear network
    /// error until the user sets a URL.
    static func customURL(path: String) -> URL {
        var base = customBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? URL(string: "http://localhost" + path)!
    }
}

// MARK: - Provider protocol

protocol AIProviderClient {
    /// Send a chat turn and return the assistant reply text.
    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String

    /// Fetch the provider's live model list and return plain model ids.
    func fetchModels(key: String, session: URLSession) async throws -> [String]
}

// MARK: - Shared HTTP helpers

/// Execute a request, map HTTP status codes to `AICoachError`, return the decoded JSON object.
func performRequest(_ req: URLRequest, session: URLSession) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse

    do {
        (data, response) = try await session.data(for: req)
    } catch {
        throw AICoachError.network(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
        throw AICoachError.network("no HTTP response")
    }

    switch http.statusCode {
    case 200...299:
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICoachError.decode
        }

        return obj
    case 401, 403:
        throw AICoachError.badKey
    case 429:
        throw AICoachError.rateLimited
    default:
        throw AICoachError.server(http.statusCode, providerErrorMessage(from: data))
    }
}

/// Best-effort extraction of a human-readable message from a provider error body.
func providerErrorMessage(from data: Data) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

    if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
    if let msg = obj["message"] as? String { return msg }

    return ""
}
