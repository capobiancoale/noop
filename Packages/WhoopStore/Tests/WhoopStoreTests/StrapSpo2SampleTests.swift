import XCTest
import WhoopProtocol
@testable import WhoopStore

/// v26 migration: the strap's OWN blood-oxygen byte (v18 @82) was decoded but dropped at stream extraction,
/// so the nightly SpO2 had no source. This proves the table exists, keys by (deviceId, ts), round-trips the
/// raw byte verbatim (percentages and status codes alike), dedupes a re-sync, scopes reads by device and
/// range, and is cleared by `deleteAllData` and the timestamp heal like its neighbours.
final class StrapSpo2SampleTests: XCTestCase {
    func testV26CreatesStrapSpo2Table() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("strapSpo2Sample"))
    }

    func testStrapSpo2PrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("strapSpo2Sample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    /// The raw byte round-trips through insert + read in ts order, status codes included, and re-inserting
    /// the same (deviceId, ts) is idempotent: the second keeps its first-seen byte, no duplicate rows.
    func testInsertRoundTripAndIdempotentReinsert() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = [
            StrapSpo2Sample(ts: 1_780_916_210, raw: 96),
            StrapSpo2Sample(ts: 1_780_916_150, raw: 32),    // a status code, kept verbatim
            StrapSpo2Sample(ts: 1_780_916_180, raw: 93),
        ]
        _ = try await store.insert(Streams(strapSpo2: rows), deviceId: "my-whoop")
        let n1 = try await store.strapSpo2CountForTest()
        XCTAssertEqual(n1, 3)

        let read = try await store.strapSpo2Samples(deviceId: "my-whoop",
                                                    from: 1_780_916_150, to: 1_780_916_210)
        XCTAssertEqual(read.map(\.ts), [1_780_916_150, 1_780_916_180, 1_780_916_210], "ascending by ts")
        XCTAssertEqual(read.map(\.raw), [32, 93, 96])

        // Re-sync with a different byte for an already-stored second: first-seen wins, nothing is added.
        let again = [StrapSpo2Sample(ts: 1_780_916_180, raw: 70), StrapSpo2Sample(ts: 1_780_916_210, raw: 96)]
        _ = try await store.insert(Streams(strapSpo2: again), deviceId: "my-whoop")
        let n2 = try await store.strapSpo2CountForTest()
        XCTAssertEqual(n2, 3)
        let after = try await store.strapSpo2Samples(deviceId: "my-whoop", from: 0, to: Int.max)
        XCTAssertEqual(after.first { $0.ts == 1_780_916_180 }?.raw, 93)
    }

    /// `[from, to]` is inclusive on both ends, another device's rows never leak in, and `limit` caps the
    /// result from the earliest second.
    func testReadRangeBoundsDeviceScopeAndLimit() async throws {
        let store = try await WhoopStore.inMemory()
        let mine = (0..<5).map { StrapSpo2Sample(ts: 1_000 + $0 * 10, raw: 90 + $0) }
        _ = try await store.insert(Streams(strapSpo2: mine), deviceId: "my-whoop")
        _ = try await store.insert(Streams(strapSpo2: [StrapSpo2Sample(ts: 1_020, raw: 71)]),
                                   deviceId: "other-device")

        let inclusive = try await store.strapSpo2Samples(deviceId: "my-whoop", from: 1_010, to: 1_030)
        XCTAssertEqual(inclusive.map(\.ts), [1_010, 1_020, 1_030], "both bounds are included")
        XCTAssertEqual(inclusive.map(\.raw), [91, 92, 93], "the other device's byte at 1020 never leaks in")

        let before = try await store.strapSpo2Samples(deviceId: "my-whoop", from: 0, to: 999)
        XCTAssertTrue(before.isEmpty)
        let after = try await store.strapSpo2Samples(deviceId: "my-whoop", from: 1_041, to: 9_999)
        XCTAssertTrue(after.isEmpty)

        let capped = try await store.strapSpo2Samples(deviceId: "my-whoop", from: 0, to: 9_999, limit: 2)
        XCTAssertEqual(capped.map(\.ts), [1_000, 1_010])
    }

    /// A strap that never reports the byte (a WHOOP 4.0) simply has no rows.
    func testEmptyStreamInsertsNothing() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_780_916_150, bpm: 60)]), deviceId: "my-whoop")
        let n = try await store.strapSpo2CountForTest()
        XCTAssertEqual(n, 0)
    }

    /// `deleteAllData` is the authoritative per-device wipe: the new table is in its list, so this device's
    /// readings go and another device's stay.
    func testDeleteAllDataRemovesTheDevicesRows() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(strapSpo2: [StrapSpo2Sample(ts: 5_000, raw: 95)]),
                                   deviceId: "my-whoop")
        _ = try await store.insert(Streams(strapSpo2: [StrapSpo2Sample(ts: 5_000, raw: 94)]),
                                   deviceId: "keep-me")
        try await store.deleteAllData(deviceId: "my-whoop")
        let mine = try await store.strapSpo2Samples(deviceId: "my-whoop", from: 0, to: Int.max)
        XCTAssertTrue(mine.isEmpty)
        let kept = try await store.strapSpo2Samples(deviceId: "keep-me", from: 0, to: Int.max)
        XCTAssertEqual(kept, [StrapSpo2Sample(ts: 5_000, raw: 94)])
    }

    /// The #547 heal purges implausible timestamps from every raw ts-keyed table, this one included.
    func testTimestampHealPurgesImplausibleRows() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_750_000_000
        let good = now - 3_600
        _ = try await store.insert(Streams(strapSpo2: [
            StrapSpo2Sample(ts: good, raw: 95),
            StrapSpo2Sample(ts: 1_250_000_000, raw: 95),          // far past
            StrapSpo2Sample(ts: now + 30 * 86_400, raw: 95),      // future
        ]), deviceId: "dev1")
        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: "2025-06-15")
        XCTAssertEqual(result.rawRowsDeleted, 2)
        let left = try await store.strapSpo2Samples(deviceId: "dev1", from: 0, to: Int.max)
        XCTAssertEqual(left.map(\.ts), [good])
    }
}
