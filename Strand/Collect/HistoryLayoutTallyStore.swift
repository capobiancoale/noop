import Foundation
import WhoopProtocol

/// Persists the `HistoryLayoutTally` in UserDefaults so the strap-log header can say which historical
/// layouts the strap has ever handed over, even after the night's offload lines have scrolled out of the
/// log ring. On-device only; nothing is sent anywhere.
enum HistoryLayoutTallyStore {
    private static let key = "historyLayoutTally.v1"

    static func load(_ defaults: UserDefaults = .standard) -> HistoryLayoutTally {
        guard let data = defaults.data(forKey: key),
              let tally = try? JSONDecoder().decode(HistoryLayoutTally.self, from: data) else { return HistoryLayoutTally() }
        return tally
    }

    /// Count one decoded chunk's records (one version per record).
    static func record(versions: [Int], at date: Date = Date(), defaults: UserDefaults = .standard) {
        guard !versions.isEmpty else { return }
        var tally = load(defaults)
        tally.record(versions: versions, at: date.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(tally) { defaults.set(data, forKey: key) }
    }

    /// The header line for a shared strap log, times in the device's own zone.
    static func summaryLine(_ defaults: UserDefaults = .standard) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM HH:mm"
        return load(defaults).summaryLine { f.string(from: Date(timeIntervalSince1970: $0)) }
    }
}
