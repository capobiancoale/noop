import XCTest
import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Runs NOOP's sleep stagers on the PhysioNet sleep-accel nights (Walch 2019) and writes, per configuration and
/// subject, the 4×4 confusion matrix PSG (rows) × NOOP (columns), classes wake/light/deep/rem.
final class SleepAccelHarness: XCTestCase {

    struct Night {
        let id: String; let start: Int; let end: Int
        let labels: [Int: Int]
        let hr: [HRSample]; let grav: [GravitySample]
    }

    static func load(_ path: String) -> Night? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var start = 0, end = 0
        var labels: [Int: Int] = [:]
        var hr: [HRSample] = []; var grav: [GravitySample] = []
        var rawLabels: [(Int, Int)] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ")
            switch p.first {
            case "W": start = Int(p[1])!; end = Int(p[2])!
            case "L": rawLabels.append((Int(p[1])!, Int(p[2])!))
            case "H": hr.append(HRSample(ts: Int(p[1])!, bpm: Int(p[2])!))
            case "G": grav.append(GravitySample(ts: Int(p[1])!, x: Double(p[2])!, y: Double(p[3])!, z: Double(p[4])!))
            default: break
            }
        }
        for (ts, s) in rawLabels {
            let cls: Int?
            switch s { case 0: cls = 0; case 1, 2: cls = 1; case 3, 4: cls = 2; case 5: cls = 3; default: cls = nil }
            if let cls { labels[(ts - start) / 30] = cls }
        }
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return Night(id: id, start: start, end: end, labels: labels, hr: hr, grav: grav)
    }

    static func cls(_ s: String) -> Int {
        switch s { case "wake": return 0; case "light": return 1; case "deep": return 2; case "rem": return 3; default: return 1 }
    }

    static func epochs(_ segs: [StageSegment], start: Int, n: Int) -> [Int] {
        var out = [Int](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let mid = start + i * 30 + 15
            while j < segs.count && segs[j].end <= mid { j += 1 }
            if j < segs.count && mid >= segs[j].start { out[i] = cls(segs[j].stage) }
        }
        return out
    }

    struct Prepared { let feats: [SleepStager.EpochFeatures]; let onset: Int; let finalWake: Int; let n: Int }

    static func prepare(_ night: Night) -> Prepared {
        let gSeg = SleepStager.rowsBetween(night.grav, start: night.start, end: night.end) { $0.ts }
        let grid = SleepStager.buildEpochGrid(start: Double(night.start), end: Double(night.end),
                                              gravTimes: gSeg.map { $0.ts }, gravDeltas: SleepStager.gravityDeltas(gSeg),
                                              hr: SleepStager.rowsBetween(night.hr, start: night.start, end: night.end) { $0.ts },
                                              rr: [], resp: [])
        let ck = SleepStager.coleKripke(SleepStager.rescaleCounts(grid.counts))
        let (onset, finalWake) = SleepStager.onsetAndFinalWake(ck)
        let feats = SleepStager.extractFeatures(grid: grid, ckFlags: ck, dogHR: SleepStager.dogHRVariability(grid.hr),
                                                onsetIdx: onset, finalWakeIdx: finalWake)
        return Prepared(feats: feats, onset: onset, finalWake: finalWake, n: grid.nEpochs)
    }

    static func stageV1(_ p: Prepared) -> [Int] {
        var labels = SleepStager.classifyEpochs(p.feats)
        labels = SleepStager.smoothLabels(labels)
        labels = SleepStager.reimposePhysiology(labels, features: p.feats, onsetIdx: p.onset, finalWakeIdx: p.finalWake)
        labels = SleepStager.mergeFragments(labels)
        for i in 0..<labels.count where i < p.onset || i > p.finalWake { labels[i] = "wake" }
        return labels.map(cls)
    }

    static func confusion(_ night: Night, _ pred: [Int]) -> [Int] {
        var cm = [Int](repeating: 0, count: 16)
        for (i, truth) in night.labels where i < pred.count { cm[truth * 4 + pred[i]] += 1 }
        return cm
    }

    func testRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SLEEPACCEL_PREP"], let out = env["SLEEPACCEL_OUT"] else {
            throw XCTSkip("SLEEPACCEL_PREP / SLEEPACCEL_OUT not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".txt") }.sorted()
        var lines: [String] = []
        func emit(_ config: String, _ id: String, _ cm: [Int]) {
            lines.append("{\"config\":\"\(config)\",\"id\":\"\(id)\",\"cm\":[\(cm.map(String.init).joined(separator: ","))]}")
        }
        for f in files {
            guard let night = Self.load(dir + "/" + f) else { continue }
            let p = Self.prepare(night)
            let shipped = SleepStager.stageSession(start: night.start, end: night.end, grav: night.grav, hr: night.hr, rr: [], resp: [])
            let shippedEpochs = Self.epochs(shipped, start: night.start, n: p.n)
            emit("V1-shipped", night.id, Self.confusion(night, shippedEpochs))
            let split = Self.stageV1(p)
            let agree = zip(split, shippedEpochs).filter { $0 == $1 }.count
            if agree != p.n { print("HARNESS split-mismatch \(night.id) \(agree)/\(p.n)") }
            let v2 = SleepStagerV2.stageSession(start: night.start, end: night.end, grav: night.grav, hr: night.hr, rr: [], resp: [])
            emit("V2-shipped", night.id, Self.confusion(night, Self.epochs(v2, start: night.start, n: p.n)))
            // V2 grid: deep gate (percentile + slope) and the deep / REM base rates.
            let feats = SleepStagerV2.features(start: night.start, end: night.end,
                                               grav: night.grav.sorted { $0.ts < $1.ts },
                                               hr: night.hr.sorted { $0.ts < $1.ts }, rr: [])
            let savedPrior = SleepStagerV2.baseLogPrior
            for thr in [0.06, 0.08, 0.10, 0.12, 0.15, 0.20] {
                for slope in [5.0, 10, 20] {
                    for dp in [0.10, 0.14, 0.18] {
                        for rp in [0.18, 0.22, 0.26] {
                            SleepStagerV2.deepGateThresh = thr; SleepStagerV2.deepGateSlope = slope
                            SleepStagerV2.baseLogPrior = ["light": log(1 - dp - rp - 0.10), "deep": log(dp),
                                                          "rem": log(rp), "awake": log(0.10)]
                            let labels = SleepStagerV2.stageEpochs(feats)
                            var segs: [StageSegment] = []
                            for (i, f) in feats.enumerated() {
                                let stage = labels[i] == "awake" ? "wake" : labels[i]
                                let s0 = i == 0 ? night.start : f.start
                                let s1 = i == feats.count - 1 ? night.end : feats[i + 1].start
                                if let last = segs.last, last.stage == stage { segs[segs.count - 1].end = s1 }
                                else { segs.append(StageSegment(start: s0, end: s1, stage: stage)) }
                            }
                            emit("V2 thr=\(thr) slope=\(Int(slope)) deep=\(dp) rem=\(rp)", night.id,
                                 Self.confusion(night, Self.epochs(segs, start: night.start, n: p.n)))
                        }
                    }
                }
            }
            SleepStagerV2.deepGateThresh = 0.20; SleepStagerV2.deepGateSlope = 5.0; SleepStagerV2.baseLogPrior = savedPrior
            print("HARNESS done \(night.id)")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("HARNESS wrote \(lines.count) rows to \(out)")
    }
}
