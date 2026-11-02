import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// RR-interval fixtures for the artefact-correction tests: a deterministic physiological generator, the
/// artefact simulations of Lipponen & Tarvainen (2019, §3) and two real excerpts from PhysioNet Fantasia.
enum RRFixtures {

    // MARK: - Deterministic generator

    /// SplitMix64: a tiny seeded PRNG so every series is reproducible on every platform.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        /// Standard normal draw (Box–Muller).
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    /// A resting RR series (ms): respiratory sinus arrhythmia at 0.25 Hz (±`rsaMs`), a slower 0.05 Hz wave
    /// (±`rsaMs`/2) and Gaussian beat-to-beat jitter, rounded to whole ms like the strap delivers.
    static func resting(count: Int, meanMs: Double = 900, rsaMs: Double = 35, jitterMs: Double = 10,
                        seed: UInt64 = 1) -> [Double] {
        var rng = SplitMix64(state: seed)
        var t = 0.0
        var out: [Double] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let rr = meanMs + rsaMs * sin(2 * Double.pi * 0.25 * t)
                + 0.5 * rsaMs * sin(2 * Double.pi * 0.05 * t + 1) + jitterMs * rng.gaussian()
            let v = rr.rounded()
            out.append(v)
            t += v / 1000
        }
        return out
    }

    /// Timestamp a series: each interval carries the whole second (from `start`) of the beat that ends it.
    static func timed(_ rr: [Double], start: Int = 1_000_000) -> [RRInterval] {
        var t = 0.0
        return rr.map { v in
            t += v / 1000
            return RRInterval(ts: start + Int(t), rrMs: Int(v.rounded()))
        }
    }

    // MARK: - Artefact simulation (Lipponen & Tarvainen 2019, §3)

    /// Beat times (ms) of an RR series, starting at 0.
    static func beats(_ rr: [Double]) -> [Double] {
        var b = [0.0]
        for v in rr { b.append(b[b.count - 1] + v) }
        return b
    }

    static func intervals(_ beats: [Double]) -> [Double] {
        zip(beats.dropFirst(), beats).map { ($0 - $1).rounded() }
    }

    /// Artefact sites k = 100n, as in the paper.
    static func sites(beatCount: Int) -> [Int] {
        Array(stride(from: 100, to: beatCount - 3, by: 100))
    }

    /// Missed beats: the detections at k = 100n are removed (two intervals merge into one).
    static func withMissedBeats(_ rr: [Double]) -> [Double] {
        let b = beats(rr)
        let drop = Set(sites(beatCount: b.count))
        return intervals(b.enumerated().filter { !drop.contains($0.offset) }.map(\.element))
    }

    /// Extra detections: a beat inserted halfway through the interval after every k = 100n.
    static func withExtraBeats(_ rr: [Double]) -> [Double] {
        let b = beats(rr)
        let add = Set(sites(beatCount: b.count))
        var out: [Double] = []
        for (i, t) in b.enumerated() {
            out.append(t)
            if add.contains(i) { out.append((t + b[i + 1]) / 2) }
        }
        return intervals(out)
    }

    /// Misaligned beats: the detections at k = 100n moved by ±q·RMSSD (alternating sign).
    static func withMisalignedBeats(_ rr: [Double], q: Double) -> [Double] {
        var b = beats(rr)
        let dt = q * (HRVAnalyzer.rmssdRaw(rr) ?? 0)
        for (n, k) in sites(beatCount: b.count).enumerated() { b[k] += n.isMultiple(of: 2) ? dt : -dt }
        return intervals(b)
    }

    // MARK: - PhysioNet Fantasia excerpts

    // RR intervals (ms) from the Fantasia database beat annotations (250 Hz ECG, so 4 ms resolution):
    //   Iyengar N, Peng C-K, Morin R, Goldberger AL, Lipsitz LA. Age-related alterations in the fractal
    //   scaling of cardiac interbeat interval dynamics. Am J Physiol 1996;271:R1078–R1084.
    //   PhysioNet (doi:10.13026/C2RG61), Open Data Commons Attribution License v1.0. See ATTRIBUTION.md.

    /// Record f1o10 (older subject), intervals 1143–1262: sinus rhythm with one annotated supraventricular
    /// premature beat — the 564 ms interval at index 60 followed by its 1020 ms compensatory pause.
    static let f1o10: [Double] = [
        896, 904, 896, 884, 836, 804, 796, 764, 784, 796, 828, 844, 848, 852, 868, 844, 836, 836, 824, 860, 868,
        868, 884, 876, 896, 884, 872, 892, 884, 872, 904, 888, 888, 920, 884, 900, 884, 876, 900, 884, 904, 928,
        900, 968, 956, 920, 960, 888, 876, 868, 848, 856, 860, 856, 860, 840, 848, 848, 840, 872, 564, 1020,
        904, 868, 880, 852, 840, 856, 860, 844, 880, 860, 848, 872, 872, 868, 864, 848, 844, 828, 828, 820, 816,
        792, 804, 796, 768, 788, 816, 840, 852, 884, 888, 892, 912, 932, 920, 916, 924, 936, 900, 920, 908, 904,
        908, 928, 908, 920, 932, 932, 916, 904, 888, 864, 868, 848, 852, 864, 848, 848,
    ]

    /// Record f1y01 (young subject), intervals 7000–7299: five minutes of large, abrupt respiratory sinus
    /// arrhythmia (RMSSD ≈ 114 ms), every beat annotated normal.
    static let f1y01: [Double] = [
        928, 804, 764, 816, 1008, 848, 852, 832, 792, 884, 952, 820, 840, 908, 784, 728, 720, 820, 1100, 864,
        820, 828, 852, 800, 788, 820, 740, 744, 716, 748, 940, 864, 928, 940, 864, 848, 904, 884, 788, 804, 908,
        908, 784, 712, 720, 1144, 896, 776, 772, 1108, 976, 932, 948, 884, 828, 868, 920, 920, 864, 920, 960,
        864, 884, 996, 948, 820, 844, 1016, 940, 812, 828, 1116, 904, 900, 932, 976, 892, 896, 892, 896, 884,
        812, 872, 852, 796, 888, 1108, 928, 952, 1000, 924, 896, 940, 916, 848, 908, 988, 860, 784, 796, 984,
        928, 808, 812, 976, 916, 852, 960, 860, 792, 816, 856, 852, 840, 996, 940, 856, 872, 900, 900, 848, 916,
        916, 880, 796, 816, 888, 904, 816, 872, 868, 792, 728, 732, 932, 1020, 796, 828, 900, 840, 800, 824,
        848, 816, 848, 860, 864, 800, 836, 760, 756, 916, 940, 836, 844, 800, 764, 752, 712, 684, 676, 756,
        1124, 872, 736, 752, 1156, 968, 796, 796, 832, 788, 732, 780, 1208, 956, 776, 852, 936, 808, 788, 1156,
        920, 880, 972, 960, 844, 796, 920, 1012, 912, 960, 928, 908, 924, 932, 872, 884, 980, 996, 852, 892,
        944, 856, 816, 956, 956, 832, 896, 932, 832, 828, 900, 900, 804, 840, 844, 792, 788, 828, 1084, 852,
        932, 904, 884, 808, 832, 860, 812, 868, 924, 828, 824, 948, 924, 868, 908, 968, 876, 768, 744, 808, 916,
        824, 884, 912, 924, 880, 952, 904, 812, 812, 784, 776, 736, 768, 1220, 980, 884, 948, 944, 824, 704,
        676, 692, 1000, 792, 720, 736, 760, 1156, 972, 924, 956, 932, 880, 856, 832, 760, 732, 844, 1124, 844,
        852, 996, 908, 828, 872, 976, 868, 820, 908, 980, 952, 944, 824, 848, 844, 792, 820,
    ]
}
