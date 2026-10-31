import XCTest
@testable import WhoopProtocol

/// Tests for the pure puffin-frame capture/serialisation type. The app's `PuffinFrameRecorder` adds
/// CoreBluetooth + file IO on top of this, but all the format-critical logic lives here.
final class PuffinCaptureTests: XCTestCase {

    /// A known-good, fully-formed WHOOP 5.0 frame (valid CRC16 header + CRC32 trailer): CLIENT_HELLO.
    private let helloHex = "aa0108000001e67123019101363e5c8d"

    private func helloFrame() -> [UInt8] { DeviceFamily.whoop5ClientHello }

    func testRecordsCanonicalHexAndProvenance() {
        let cap = PuffinCapture()
        let rec = cap.record(frame: helloFrame(), char: "fd4b0003", tsMs: 1_700_000_000_123, hr: 62)

        XCTAssertEqual(cap.count, 1)
        // hex is the decoder's canonical rawHex — round-trips through parsing, lowercase, no spaces.
        XCTAssertEqual(rec.hex, helloHex)
        XCTAssertEqual(rec.char, "fd4b0003")
        XCTAssertEqual(rec.tsMs, 1_700_000_000_123)
        XCTAssertEqual(rec.hr, 62)
        XCTAssertTrue(rec.ok)
        XCTAssertEqual(rec.crcOK, true)
    }

    func testNilHeartRateIsAllowed() {
        let cap = PuffinCapture()
        let rec = cap.record(frame: helloFrame(), char: "fd4b0005", tsMs: 1, hr: nil)
        XCTAssertNil(rec.hr)
    }

    func testMalformedFrameIsCapturedButFlaggedNotOK() {
        let cap = PuffinCapture()
        // Truncated garbage: not a valid puffin envelope.
        let rec = cap.record(frame: [0xAA, 0x01, 0x00], char: "fd4b0007", tsMs: 5, hr: nil)
        XCTAssertFalse(rec.ok)
        // We still keep the raw bytes — an un-parseable frame is exactly what a mapper wants to see.
        XCTAssertEqual(rec.hex, "aa0100")
        XCTAssertEqual(cap.count, 1)
    }

    func testReset() {
        let cap = PuffinCapture()
        cap.record(frame: helloFrame(), char: "fd4b0003", tsMs: 1, hr: nil)
        cap.reset()
        XCTAssertEqual(cap.count, 0)
    }

    func testEncodedJSONUsesSnakeCaseKeys() throws {
        let cap = PuffinCapture()
        cap.record(frame: helloFrame(), char: "fd4b0003", tsMs: 7, hr: 55)
        let data = try cap.encodedJSON()
        let obj = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let first = try XCTUnwrap(obj?.first)
        XCTAssertEqual(first["hex"] as? String, helloHex)
        XCTAssertEqual(first["ts_ms"] as? Int, 7)
        XCTAssertEqual(first["hr"] as? Int, 55)
        XCTAssertEqual(first["crc_ok"] as? Bool, true)
        XCTAssertNotNil(first["type_name"])
    }

    /// The capture file's `hex` projection must be a drop-in `frames.json` fixture.
    func testFramesFixtureJSONIsParityCompatible() throws {
        let cap = PuffinCapture()
        cap.record(frame: helloFrame(), char: "fd4b0003", tsMs: 1, hr: nil)
        cap.record(frame: helloFrame(), char: "fd4b0005", tsMs: 2, hr: 60)
        let data = try cap.framesFixtureJSON()
        let obj = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(obj?.count, 2)
        // Each entry has exactly the one key the fixture decoder reads.
        XCTAssertEqual(obj?.first?.keys.sorted(), ["hex"])
        XCTAssertEqual(obj?.first?["hex"] as? String, helloHex)
    }

    /// Only type-47 records in the v20/v21 optical layouts qualify for the offload sample.
    func testOpticalHistoryRecordFilter() {
        func frame(type: UInt8, version: UInt8) -> [UInt8] {
            var f = [UInt8](repeating: 0, count: 40)
            f[0] = 0xAA; f[8] = type; f[9] = version
            return f
        }
        XCTAssertTrue(PuffinCapture.isOpticalHistoryRecord(frame(type: 0x2f, version: 20)))
        XCTAssertTrue(PuffinCapture.isOpticalHistoryRecord(frame(type: 0x2f, version: 21)))
        XCTAssertFalse(PuffinCapture.isOpticalHistoryRecord(frame(type: 0x2f, version: 18)))
        XCTAssertFalse(PuffinCapture.isOpticalHistoryRecord(frame(type: 0x2f, version: 26)))
        XCTAssertFalse(PuffinCapture.isOpticalHistoryRecord(frame(type: 0x31, version: 21)))   // metadata
        XCTAssertFalse(PuffinCapture.isOpticalHistoryRecord(Array(frame(type: 0x2f, version: 21).prefix(9))))
        XCTAssertFalse(PuffinCapture.isOpticalHistoryRecord(helloFrame()))
    }

    func testHistoryLogRoundTripsAndDropsATruncatedTail() {
        var v18 = [UInt8](repeating: 7, count: 124); v18[8] = 0x2f; v18[9] = 18
        var v26 = [UInt8](repeating: 9, count: 84); v26[8] = 0x2f; v26[9] = 26
        XCTAssertTrue(PuffinCapture.isHistoryRecord(v18))
        XCTAssertFalse(PuffinCapture.isHistoryRecord(helloFrame()))
        let entry = PuffinCapture.historyLogEntry(v18)
        XCTAssertEqual(Array(entry.prefix(2)), [124, 0])
        let log = entry + PuffinCapture.historyLogEntry(v26)
        XCTAssertEqual(PuffinCapture.parseHistoryLog(log), [v18, v26])
        XCTAssertEqual(PuffinCapture.parseHistoryLog(Array(log.dropLast(5))), [v18])
    }
}
