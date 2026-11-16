import XCTest
@testable import Strand

/// Custom (Ollama) connect: the pure URL-candidate helper and `connectCustom()` driven through the
/// DEBUG `fetchModelsOverride` seam (no network). The base URL lives in UserDefaults, so every test
/// saves and restores the keys it touches.
@MainActor
final class AICoachConnectCustomTests: XCTestCase {

    private let keys = [AIProvider.customBaseURLKey, "ai.customConnected", "ai.model", "ai.provider"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private func makeEngine(url: String) -> AICoachEngine {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-aicoach-connect"))
        engine.provider = .custom
        engine.customConnected = false
        engine.customBaseURL = url
        return engine
    }

    // MARK: customURLCandidates

    func testCandidatesBareHostPort() {
        XCTAssertEqual(AICoachEngine.customURLCandidates("192.168.1.5:11434"),
                       ["http://192.168.1.5:11434", "http://192.168.1.5:11434/v1"])
    }

    func testCandidatesTrailingSlash() {
        XCTAssertEqual(AICoachEngine.customURLCandidates("http://mac.local:11434/"),
                       ["http://mac.local:11434", "http://mac.local:11434/v1"])
    }

    func testCandidatesAlreadyV1() {
        XCTAssertEqual(AICoachEngine.customURLCandidates("http://mac.local:11434/v1"),
                       ["http://mac.local:11434/v1"])
    }

    func testCandidatesHttpsPathWithV1AndSlash() {
        XCTAssertEqual(AICoachEngine.customURLCandidates("https://x.example/api/v1/"),
                       ["https://x.example/api/v1"])
    }

    func testCandidatesBlank() {
        XCTAssertEqual(AICoachEngine.customURLCandidates("  "), [])
    }

    // MARK: connectCustom

    func testConnectSuccessStoresAnsweringCandidateAndPicksNoopCoach() async {
        let engine = makeEngine(url: "mac.local:11434")
        // Only the /v1 address answers.
        engine.fetchModelsOverride = { _, _ in
            guard AIProvider.customBaseURL.hasSuffix("/v1") else { throw AICoachError.network("refused") }
            return ["llama3.1", "noop-coach"]
        }
        await engine.connectCustom()

        XCTAssertTrue(engine.customConnected)
        XCTAssertFalse(engine.connecting)
        XCTAssertNil(engine.errorText)
        XCTAssertEqual(engine.customBaseURL, "http://mac.local:11434/v1")
        XCTAssertEqual(engine.model, "noop-coach")
        XCTAssertTrue(engine.availableModels.contains("llama3.1"))
    }

    func testConnectKeepsExistingModelWhenNoNoopCoach() async {
        let engine = makeEngine(url: "http://mac.local:11434/v1")
        engine.model = "qwen2.5"
        engine.fetchModelsOverride = { _, _ in ["qwen2.5", "llama3.1"] }
        await engine.connectCustom()
        XCTAssertTrue(engine.customConnected)
        XCTAssertEqual(engine.model, "qwen2.5")
    }

    func testConnectPicksFirstModelWhenNoneChosen() async {
        let engine = makeEngine(url: "http://mac.local:11434/v1")
        engine.model = ""
        engine.fetchModelsOverride = { _, _ in ["b-model", "a-model"] }
        await engine.connectCustom()
        XCTAssertEqual(engine.model, "a-model")
    }

    func testConnectStillConnectsOn404() async {
        let engine = makeEngine(url: "http://mac.local:11434/v1")
        engine.fetchModelsOverride = { _, _ in throw AICoachError.server(404, "") }
        await engine.connectCustom()
        XCTAssertTrue(engine.customConnected)
        XCTAssertNil(engine.errorText)
        XCTAssertEqual(engine.customBaseURL, "http://mac.local:11434/v1")
    }

    func testConnectNetworkFailureStaysDisconnectedAndRestoresText() async {
        let engine = makeEngine(url: "  mac.local:11434 ")
        engine.fetchModelsOverride = { _, _ in throw AICoachError.network("could not connect") }
        await engine.connectCustom()

        XCTAssertFalse(engine.customConnected)
        XCTAssertFalse(engine.connecting)
        XCTAssertEqual(engine.customBaseURL, "  mac.local:11434 ")
        XCTAssertNotNil(engine.errorText)
        XCTAssertFalse((engine.errorText ?? "").isEmpty)
    }
}
