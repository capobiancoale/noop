import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// Opt-in compaction of old hrSample / ppgHrSample rows. Every test uses an in-memory store and
/// timestamps far older than the 14-day minimum-age guard.
final class StreamCompactionTests: XCTestCase {

    /// A UTC-midnight-aligned base (2023-11-14 00:00 UTC), a multiple of 86 400 and of 60.
    private let day0 = 1_699_920_000
    private let dev = "my-whoop"

    private func count(_ store: WhoopStore, _ table: String) async throws -> Int {
        try await store.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func hrRows(_ store: WhoopStore, device: String? = nil) async throws -> [[Int]] {
        let d = device ?? dev
        return try await store.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, bpm FROM hrSample WHERE deviceId = ? ORDER BY ts",
                             arguments: [d]).map { row -> [Int] in
                let ts: Int = row["ts"]
                let bpm: Int = row["bpm"]
                return [ts, bpm]
            }
        }
    }

    /// One row per second for `seconds` seconds from `start`, bpm = 60 + (i % 7).
    private func secondly(from start: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: start + $0, bpm: 60 + ($0 % 7)) }
    }

    func testMinuteMediansOddAndEven() async throws {
        let store = try await WhoopStore.inMemory()
        // minute 0: five rows 60,70,80,90,100 -> odd median 80
        // minute 1: four rows 60,62,64,66 -> even median (62+64+1)/2 = 63
        var hr: [HRSample] = []
        for (i, b) in [60, 70, 80, 90, 100].enumerated() { hr.append(HRSample(ts: day0 + i, bpm: b)) }
        for (i, b) in [66, 60, 64, 62].enumerated() { hr.append(HRSample(ts: day0 + 60 + i, bpm: b)) }
        try await store.insert(Streams(hr: hr), deviceId: dev)

        let report = try await store.compactOldStreams(cutoff: day0 + 86_400)
        XCTAssertTrue(report.finished)
        XCTAssertEqual(report.hrRowsRemoved, 7)
        let rows = try await hrRows(store)
        XCTAssertEqual(rows, [[day0, 80], [day0 + 60, 63]])
    }

    func testRowsAtOrAfterCutoffAreUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        let cutoff = day0 + 86_400
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 120)), deviceId: dev)
        // Exactly at the cutoff and after it: must stay at full resolution.
        try await store.insert(Streams(hr: secondly(from: cutoff, seconds: 120)), deviceId: dev)
        _ = try await store.compactOldStreams(cutoff: cutoff)
        let rows = try await hrRows(store)
        XCTAssertEqual(rows.filter { $0[0] < cutoff }.count, 2)
        XCTAssertEqual(rows.filter { $0[0] >= cutoff }.count, 120)
    }

    func testCutoffIsRoundedDownToWholeMinute() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 120)), deviceId: dev)
        // Cutoff 90 s in: minute 0 is compacted, minute 1 (60..119) is not (it is not fully before the cutoff).
        _ = try await store.compactOldStreams(cutoff: day0 + 90)
        let rows = try await hrRows(store)
        XCTAssertEqual(rows.filter { $0[0] < day0 + 60 }.count, 1)
        XCTAssertEqual(rows.filter { $0[0] >= day0 + 60 }.count, 60)
    }

    func testIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 600)), deviceId: dev)
        let first = try await store.compactOldStreams(cutoff: day0 + 86_400)
        XCTAssertEqual(first.hrRowsRemoved, 590)
        let before = try await hrRows(store)
        let second = try await store.compactOldStreams(cutoff: day0 + 86_400)
        XCTAssertEqual(second.rowsRemoved, 0)
        let after = try await hrRows(store)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.count, 10)
    }

    func testBatchBoundariesAcrossDays() async throws {
        let store = try await WhoopStore.inMemory()
        // Rows straddling a UTC day boundary and spanning three windows.
        var hr: [HRSample] = []
        hr += secondly(from: day0 + 86_400 - 30, seconds: 60)       // 30 s before + 30 s after the boundary
        hr += secondly(from: day0 + 2 * 86_400 + 5, seconds: 50)
        hr += secondly(from: day0, seconds: 10)
        try await store.insert(Streams(hr: hr), deviceId: dev)
        let cutoff = day0 + 3 * 86_400
        let report = try await store.compactOldStreams(cutoff: cutoff)
        XCTAssertEqual(report.windowsTotal, 3)
        XCTAssertEqual(report.completedUpTo, cutoff)
        let rows = try await hrRows(store)
        // minutes: day0+0, (day0+86340 and day0+86400), day0+2d+0
        XCTAssertEqual(rows.map { $0[0] },
                       [day0, day0 + 86_340, day0 + 86_400, day0 + 2 * 86_400])
    }

    func testProgressCallbackReachesTotal() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 30)), deviceId: dev)
        try await store.insert(Streams(hr: secondly(from: day0 + 86_400, seconds: 30)), deviceId: dev)
        final class Box: @unchecked Sendable { var last = (0, 0) }
        let box = Box()
        _ = try await store.compactOldStreams(cutoff: day0 + 2 * 86_400, progress: { done, total in
            box.last = (done, total)
        })
        XCTAssertEqual(box.last.0, 2)
        XCTAssertEqual(box.last.1, 2)
    }

    func testDryRunCountsEqualRealDeletionsAndWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 300)), deviceId: dev)
        try await store.insert(Streams(hr: secondly(from: day0 + 86_400, seconds: 200)), deviceId: dev)
        // PPG: a minute folded into hr (same minute as measured rows) and a PPG-only minute.
        try await store.insert(Streams(ppgHr: (0..<60).map {
            PpgHrSample(ts: day0 + $0, bpm: 62, conf: 0.5) }), deviceId: dev)
        try await store.insert(Streams(ppgHr: (0..<60).map {
            PpgHrSample(ts: day0 + 7_200 + $0, bpm: 70 + ($0 % 3), conf: 0.4 + Double($0 % 5) / 10) }),
                               deviceId: dev)
        let cutoff = day0 + 3 * 86_400
        let hrBefore = try await count(store, "hrSample")
        let ppgBefore = try await count(store, "ppgHrSample")

        let dry = try await store.compactOldStreams(cutoff: cutoff, dryRun: true)
        XCTAssertTrue(dry.dryRun)
        let hrMid = try await count(store, "hrSample")
        let ppgMid = try await count(store, "ppgHrSample")
        XCTAssertEqual(hrMid, hrBefore)
        XCTAssertEqual(ppgMid, ppgBefore)
        XCTAssertGreaterThan(dry.estimatedBytes, 0)

        let real = try await store.compactOldStreams(cutoff: cutoff)
        let hrAfter = try await count(store, "hrSample")
        let ppgAfter = try await count(store, "ppgHrSample")
        XCTAssertEqual(dry.hrRowsRemoved, real.hrRowsRemoved)
        XCTAssertEqual(dry.ppgRowsRemoved, real.ppgRowsRemoved)
        XCTAssertEqual(dry.rowsRemoved, real.rowsRemoved)
        XCTAssertEqual(dry.estimatedBytes, real.estimatedBytes)
        XCTAssertEqual(hrBefore - hrAfter, real.hrRowsRemoved)
        XCTAssertEqual(ppgBefore - ppgAfter, real.ppgRowsRemoved)
    }

    func testMultipleDevicesAreCompactedIndependently() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: (0..<60).map { HRSample(ts: day0 + $0, bpm: 50) }), deviceId: "a")
        try await store.insert(Streams(hr: (0..<60).map { HRSample(ts: day0 + $0, bpm: 90) }), deviceId: "b")
        _ = try await store.compactOldStreams(cutoff: day0 + 86_400)
        let a = try await hrRows(store, device: "a")
        let b = try await hrRows(store, device: "b")
        XCTAssertEqual(a, [[day0, 50]])
        XCTAssertEqual(b, [[day0, 90]])
    }

    func testPpgOnlyMinuteStaysPpgWithMedianAndMinConf() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: day0 + 1, bpm: 60, conf: 0.9),
            PpgHrSample(ts: day0 + 2, bpm: 80, conf: 0.3),
            PpgHrSample(ts: day0 + 3, bpm: 70, conf: 0.6),
        ]), deviceId: dev)
        _ = try await store.compactOldStreams(cutoff: day0 + 86_400)
        let hrN = try await count(store, "hrSample")
        let ppgN = try await count(store, "ppgHrSample")
        XCTAssertEqual(hrN, 0)
        XCTAssertEqual(ppgN, 1)
        let buckets = try await store.hrBuckets(deviceId: dev, from: day0, to: day0 + 59, bucketSeconds: 60)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].bpm, 70, accuracy: 0.0001)
        XCTAssertEqual(buckets[0].conf, 0.3, accuracy: 0.0001)
    }

    func testPpgFoldedIntoMeasuredMinuteAndDeleted() async throws {
        let store = try await WhoopStore.inMemory()
        // 2 measured seconds (50, 52) + 3 PPG-only seconds (70, 72, 74): coalesced values sorted
        // 50,52,70,72,74 -> median 70. The minute's PPG rows are removed so they cannot re-appear.
        try await store.insert(Streams(hr: [HRSample(ts: day0, bpm: 50), HRSample(ts: day0 + 1, bpm: 52)]),
                               deviceId: dev)
        try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: day0 + 1, bpm: 99, conf: 0.9),    // shadowed by measured second
            PpgHrSample(ts: day0 + 2, bpm: 70, conf: 0.8),
            PpgHrSample(ts: day0 + 3, bpm: 72, conf: 0.8),
            PpgHrSample(ts: day0 + 4, bpm: 74, conf: 0.8),
        ]), deviceId: dev)
        _ = try await store.compactOldStreams(cutoff: day0 + 86_400)
        let rows = try await hrRows(store)
        XCTAssertEqual(rows, [[day0, 70]])
        let ppgN = try await count(store, "ppgHrSample")
        XCTAssertEqual(ppgN, 0)
        // Readers still see exactly one value for the minute (no PPG ghost rows).
        let read = try await store.hrSamples(deviceId: dev, from: day0, to: day0 + 59, limit: 100)
        XCTAssertEqual(read.count, 1)
    }

    func testProtectedTablesAreUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: nil)
        let n = 120
        try await store.insert(Streams(
            hr: secondly(from: day0, seconds: n),
            rr: (0..<n).map { RRInterval(ts: day0 + $0, rrMs: 800 + $0) },
            spo2: (0..<n).map { SpO2Sample(ts: day0 + $0, red: 1, ir: 2) },
            skinTemp: (0..<n).map { SkinTempSample(ts: day0 + $0, raw: 3) },
            resp: (0..<n).map { RespSample(ts: day0 + $0, raw: 4) },
            gravity: (0..<n).map { GravitySample(ts: day0 + $0, x: 0, y: 0, z: 1) },
            steps: (0..<n).map { StepSample(ts: day0 + $0, counter: $0) },
            sleepState: (0..<n).map { SleepStateSample(ts: day0 + $0, state: 1) },
            strapSpo2: (0..<n).map { StrapSpo2Sample(ts: day0 + $0, raw: 95) },
            battery: (0..<n).map { BatterySample(ts: day0 + $0, soc: 50, mv: 3900) }), deviceId: dev)
        try await store.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES ('my-whoop-noop', '2023-11-14')")
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop-noop', '2023-11-14', 'k', 1.5)")
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs) VALUES ('my-whoop-noop', 1699920000, 1699950000)")
            try db.execute(sql: "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('my-whoop-noop', 1699920000, 1699923600, 'run', 'manual')")
            try db.execute(sql: "INSERT INTO journal (deviceId, day, question, answeredYes) VALUES ('my-whoop-noop', '2023-11-14', 'q', 1)")
            try db.execute(sql: "INSERT INTO appleDaily (deviceId, day) VALUES ('apple-health', '2023-11-14')")
            try db.execute(sql: "INSERT INTO cursors (name, value) VALUES ('c', 7)")
        }
        let protected = ["rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
                         "stepSample", "sleepStateSample", "strapSpo2Sample", "battery", "event",
                         "dailyMetric", "metricSeries", "sleepSession", "workout", "journal", "appleDaily",
                         "cursors", "device", "wodLog", "labMarker", "rawBatch"]
        var before: [String: Int] = [:]
        for t in protected { before[t] = try await count(store, t) }

        let report = try await store.compactOldStreams(cutoff: day0 + 86_400)
        XCTAssertEqual(report.hrRowsRemoved, n - 2)

        for t in protected {
            let after = try await count(store, t)
            XCTAssertEqual(after, before[t], "table \(t) must not change")
        }
    }

    func testRefusesCutoffNewerThanFourteenDays() async throws {
        let store = try await WhoopStore.inMemory()
        let now = day0 + 100 * 86_400
        do {
            _ = try await store.compactOldStreams(cutoff: now - 3 * 86_400, now: now)
            XCTFail("expected cutoffTooRecent")
        } catch let e as StreamCompactionError {
            XCTAssertEqual(e, .cutoffTooRecent)
        }
        // Exactly 14 days old is allowed.
        _ = try await store.compactOldStreams(cutoff: now - 14 * 86_400, now: now)
    }

    func testSkipBeforeLeavesEarlierRowsAlone() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 120)), deviceId: dev)
        try await store.insert(Streams(hr: secondly(from: day0 + 86_400, seconds: 120)), deviceId: dev)
        _ = try await store.compactOldStreams(cutoff: day0 + 3 * 86_400, skipBefore: day0 + 86_400)
        let rows = try await hrRows(store)
        XCTAssertEqual(rows.filter { $0[0] < day0 + 86_400 }.count, 120)
        XCTAssertEqual(rows.filter { $0[0] >= day0 + 86_400 }.count, 2)
    }

    func testMedianHelpers() {
        XCTAssertEqual(StreamCompaction.medianInt(sorted: [5]), 5)
        XCTAssertEqual(StreamCompaction.medianInt(sorted: [1, 2]), 2)      // (1+2+1)/2
        XCTAssertEqual(StreamCompaction.medianInt(sorted: [1, 2, 9]), 2)
        XCTAssertEqual(StreamCompaction.minuteFloor(119), 60)
        XCTAssertEqual(StreamCompaction.minuteFloor(120), 120)
    }

    func testReclaimSpaceRefusesWhenDiskTooSmallAndRunsWhenEnough() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-compact-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let store = try await WhoopStore(path: path)
        try await store.insert(Streams(hr: secondly(from: day0, seconds: 3_000)), deviceId: dev)
        _ = try await store.compactOldStreams(cutoff: day0 + 86_400)

        let refused = try await store.reclaimSpace(availableBytes: { _ in 0 })
        guard case .notEnoughFreeSpace = refused else { return XCTFail("expected refusal, got \(refused)") }
        let unknown = try await store.reclaimSpace(availableBytes: { _ in nil })
        XCTAssertEqual(unknown, .unavailable)

        let ok = try await store.reclaimSpace(availableBytes: { _ in Int64.max })
        guard case .reclaimed(let before, let after) = ok else { return XCTFail("expected reclaim, got \(ok)") }
        XCTAssertLessThanOrEqual(after, before)
        let remaining = try await count(store, "hrSample")
        XCTAssertEqual(remaining, 50)
    }

    func testReclaimSpaceUnavailableForInMemoryStore() async throws {
        let store = try await WhoopStore.inMemory()
        let r = try await store.reclaimSpace(availableBytes: { _ in Int64.max })
        XCTAssertEqual(r, .unavailable)
    }
}
