import Foundation
import CoreBluetooth
import WhoopProtocol

/// App-side glue around the pure `PuffinCapture`: gates on a user toggle, stamps each frame with a
/// wall-clock time and the live (standard-profile) heart rate, and persists the growing capture to a
/// JSON file under Application Support. Read-only with respect to the strap — it only records frames
/// that already arrived, it never writes to the device — so it is always safe to leave on.
///
/// `@MainActor` because it reads `LiveState.heartRate` and updates published capture status; the
/// BLEManager delegate callbacks that feed it are already on the main queue.
@MainActor
final class PuffinFrameRecorder {
    /// UserDefaults flag, mirrored by the Settings toggle (`@AppStorage`). Separate from the puffin
    /// *probe* switch (`PuffinExperiment`): capturing is passive/safe, probing actively guesses.
    static let enabledKey = "noopPuffinCapture"

    /// Flush to disk every this-many frames so a crash/yank loses at most a handful of frames.
    private static let flushEvery = 25

    /// Soft cap on the total size of the puffin-captures directory (#27). One file is written per app
    /// launch and never trimmed, so without a cap the directory grows without bound — an experimental
    /// capture toggle a 5/MG user left on reached 19 GB. After each flush, oldest files are evicted
    /// (by filename, which is timestamp-sorted) until the total is back under the cap. Never deletes
    /// the file the current session is still writing.
    private static let directorySoftCapBytes = 50 * 1024 * 1024

    /// Most v20/v21 optical history records kept per capture file. Each is 1.2-2.1 kB, so this bounds the
    /// file to a few MB (the whole JSON is rewritten on every flush, on the main actor) while still holding
    /// minutes of contiguous signal, enough to tell the optical channels apart offline.
    private static let maxOpticalHistoryFrames = 1_200

    private weak var state: LiveState?
    private let buffer = PuffinCapture()
    private var sinceFlush = 0
    private var opticalHistoryCaptured = 0
    private var fileURL: URL?
    private var historyHandle: FileHandle?
    private var historyDay: String?

    init(state: LiveState) {
        self.state = state
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// `<AppSupport>/OpenWhoop/puffin-captures/`, created on demand.
    private static func captureDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("puffin-captures", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Record one puffin frame (off `fd4b0003/0004/0005/0007`). No-op unless capture is enabled.
    func capture(frame: [UInt8], char: CBUUID) {
        guard isEnabled else { return }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        buffer.record(frame: frame, char: char.uuidString.lowercased(),
                      tsMs: tsMs, hr: state?.heartRate)
        sinceFlush += 1
        state?.puffinCaptureCount = buffer.count
        if sinceFlush >= Self.flushEvery { flush() }
    }

    /// Record a historical-offload frame, but only a v20/v21 optical record and only up to
    /// `maxOpticalHistoryFrames` per capture file. Offload traffic otherwise stays out of the capture; these
    /// records are kept because finding the red and infrared channels in them is the prerequisite for any
    /// SpO2 computed from a 5/MG's light (`Tools/spo2-validation`; the strap's own percentage in v18 byte 82
    /// is a separate route). No-op unless capture is enabled.
    func captureOpticalHistory(frame: [UInt8], char: CBUUID) {
        guard isEnabled, opticalHistoryCaptured < Self.maxOpticalHistoryFrames,
              PuffinCapture.isOpticalHistoryRecord(frame) else { return }
        opticalHistoryCaptured += 1
        capture(frame: frame, char: char)
    }

    /// Append every WHOOP 5.0 history record (any layout) to the day's append-only log. The decoder keeps
    /// only the mapped fields, so without this the unmapped part of v18, where the SpO2 inputs may sit, is
    /// lost; a night of records is about 4 MB. Each record is written straight through, so a background
    /// kill loses nothing. No-op unless capture is enabled.
    func captureHistoryRecord(frame: [UInt8]) {
        guard isEnabled, PuffinCapture.isHistoryRecord(frame) else { return }
        let day = Self.dayFormatter.string(from: Date())
        if historyDay != day {
            try? historyHandle?.close()
            historyHandle = nil
            historyDay = day
            guard let dir = try? Self.historyDirectory() else { return }
            let url = dir.appendingPathComponent("history-\(day).bin")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                Self.evictOldHistoryLogs(keeping: url)
            }
            historyHandle = try? FileHandle(forWritingTo: url)
            _ = try? historyHandle?.seekToEnd()
        }
        try? historyHandle?.write(contentsOf: Data(PuffinCapture.historyLogEntry(frame)))
    }

    /// History-record logs written in the last `window` seconds, oldest first.
    static func recentHistoryLogs(within window: TimeInterval = 36 * 3600, now: Date = Date()) -> [URL] {
        guard let dir = try? historyDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { url in
                guard url.pathExtension == "bin",
                      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate else { return false }
                return now.timeIntervalSince(modified) <= window
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `<AppSupport>/OpenWhoop/history-records/`, created on demand.
    private static func historyDirectory() throws -> URL {
        let dir = try captureDirectory().deletingLastPathComponent()
            .appendingPathComponent("history-records", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Keep the history logs under `historyDirectorySoftCapBytes`, oldest day first, never today's file.
    private static func evictOldHistoryLogs(keeping keep: URL) {
        let fm = FileManager.default
        guard let dir = try? historyDirectory(),
              let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let files = entries
            .filter { $0.pathExtension == "bin" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > historyDirectorySoftCapBytes && file.url != keep {
            if (try? fm.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    /// About two weeks of nightly history-record logs.
    private static let historyDirectorySoftCapBytes = 80 * 1024 * 1024

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// Write the full capture to disk (best-effort, atomic). Called periodically and on disconnect.
    func flush() {
        guard buffer.count > 0 else { return }
        do {
            let url = try sessionFileURL()
            let data = try buffer.encodedJSON()
            try data.write(to: url, options: .atomic)
            sinceFlush = 0
            state?.puffinCaptureURL = url
            // Bound on-disk growth (#27): evict oldest captures beyond the soft cap, never the
            // file this session is still writing.
            Self.evictOldCaptures(keeping: url)
        } catch {
            // Best-effort: a failed flush just means the next one rewrites the whole file.
        }
    }

    /// Enforce the directory soft cap by deleting the oldest capture files (best-effort). Filenames are
    /// `puffin-yyyyMMdd-HHmmss.json`, so lexicographic order is chronological — delete from the front
    /// until the total is back under the cap. `keep` (the active session file) is never deleted.
    private static func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let dir = try? captureDirectory() else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        // Sort oldest-first by name (timestamped). Pair each with its size up front.
        let files = entries
            .filter { $0.pathExtension == "json" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > directorySoftCapBytes else { break }
            if file.url == keep { continue }   // never delete the active session file
            do {
                try fm.removeItem(at: file.url)
                total -= file.size
            } catch {
                // Best-effort: skip a file we couldn't remove; the next flush retries.
            }
        }
    }

    /// Capture files written in the last `window` seconds, oldest first. One file is written per app
    /// launch, so a night the app was relaunched through (iOS restarts it in the background) spans several
    /// files; the export bundles them all so the night's records are not left behind with an older file.
    static func recentCaptureFiles(within window: TimeInterval = 36 * 3600, now: Date = Date()) -> [URL] {
        guard let dir = try? captureDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { url in
                guard url.pathExtension == "json",
                      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate else { return false }
                return now.timeIntervalSince(modified) <= window
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One file per recorder lifetime (i.e. per app launch), named on first use. Re-flushing rewrites
    /// the same file, so the capture file always holds the complete session.
    private func sessionFileURL() throws -> URL {
        if let url = fileURL { return url }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = try Self.captureDirectory().appendingPathComponent("puffin-\(stamp).json")
        fileURL = url
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
