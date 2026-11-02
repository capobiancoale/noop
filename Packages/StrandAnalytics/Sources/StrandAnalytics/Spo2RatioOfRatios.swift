import Foundation

// Spo2RatioOfRatios.swift - the pulse-oximetry "ratio of ratios" maths, as a pure, offline-validated engine.
//
// A pulse oximeter shines two wavelengths through tissue and watches how much each one pulses. By
// Beer-Lambert the pulsatile (AC) part of the absorbance, normalised by the steady (DC) part, depends on the
// absorbers in the arterial blood. Oxyhaemoglobin absorbs very little red light (about 660 nm) and a fair bit
// of infrared (about 880-940 nm); deoxyhaemoglobin is the other way round. So the ratio of ratios
//
//     R = (AC_red / DC_red) / (AC_ir / DC_ir)
//
// falls as saturation rises. At normal saturation red pulses LESS than IR and R is below 1 (about 0.4-0.5 at
// 97 %); a desaturating finger pushes R up towards and past 1.
//
// WHAT THIS IS NOT: a percentage. The map from R to SpO2 is a property of the device (LED spectra, optics,
// photodiode, skin path length) and is fitted per product against arterial blood gases (Webster 1997, Design
// of Pulse Oximeters; the Maxim/ADI MAX3010x application notes). `genericSpo2` is the textbook straight line,
// an UNCALIBRATED reference curve kept for tests and for the offline validation tool. It is never a displayed
// value, and nothing that comes out of this file may reach the UI without a device-specific calibration.
//
// VALIDATION (offline, Python/scipy, mirrored by the tests here; numbers and method in
// Tools/spo2-validation/README.md): the open PhysioNet "Pulse Transit Time PPG" set (finger MAX30101, red 660 /
// IR 880 nm, 22 subjects, 66 records). R is about 0.44 at a reference SpO2 of about 97 %; the generic curve
// 110 - 25 R then has an ARMS of about 2.4 points; the within-subject spread of R is about 0.7 points; R from
// a 25 Hz copy equals R at 500 Hz (median difference 0.03 points); R from 1 Hz point samples (one value per
// second) with the moving-median residual below differs from the dense value by a median 0.7 points per 60 s
// window. That is a finger probe at rest and while walking, not a wrist strap: it shows the maths is sound,
// not that a wrist number would be.
//
// STATUS: nothing in the app calls this yet. It needs red and infrared channels that are IDENTIFIED as such
// from the strap (the WHOOP 5.0 does not expose them that way today; the 4.0 v24 record banks one red/IR pair
// per second, which is what `secondSampleRatio` is for). `channelOrder` exists because labels are not always
// trustworthy: it is how the PhysioNet set's swapped red/IR labels were caught.
//
// Pure: Foundation only, no I/O, no state, no UI strings, no em-dashes.
public enum Spo2RatioOfRatios {

    // MARK: - Constants

    /// Length of one analysis window. Ten seconds holds about ten beats at rest, enough for a stable AC
    /// estimate, and short enough that a motion burst spoils one window rather than the whole record.
    public static let windowSeconds: Double = 10.0
    /// Hop between window starts (50 % overlap).
    public static let stepSeconds: Double = 5.0
    /// Band that isolates the cardiac pulse and drops baseline wander and respiration (low edge)...
    public static let passBandLowHz: Double = 0.5
    /// ...and high-frequency noise (upper edge; clamped to 0.45 of the sample rate for slow recordings).
    public static let passBandHighHz: Double = 5.0
    /// A real pulse is shared by both wavelengths, so the band-passed red and IR windows must correlate.
    /// Motion artefact and sensor noise are largely independent between channels and fail this gate.
    public static let minCorrelation: Double = 0.9
    /// Accepted perfusion index (AC rms / DC) of the IR channel. Below the floor there is no usable pulse;
    /// above the ceiling the channel is saturated or dominated by motion.
    public static let perfusionRange: ClosedRange<Double> = 0.0002...0.10
    /// Fewest accepted windows before an estimate is given at all; fewer is "not enough clean signal".
    public static let minAcceptedWindows: Int = 3
    /// Below this sample rate a 5 Hz band is not representable and the windows are not analysed.
    public static let minSampleRateHz: Double = 4.0
    /// Fewest one-per-second samples `secondSampleRatio` accepts (one minute).
    public static let secondSampleWindow: Int = 60
    /// Width (samples) of the centred moving median that `secondSampleRatio` uses as the slow baseline.
    public static let secondSampleMedianSpan: Int = 5
    /// `channelOrder` calls the labels as given when R is at most this, swapped when R is at least its inverse.
    public static let channelOrderMargin: Double = 0.85

    // MARK: - Types

    /// One analysis window of a dense red/IR recording.
    public struct Window: Equatable, Sendable {
        /// Seconds from the start of the series to the first sample of the window.
        public let start: Double
        /// R for this window: perfusionRed / perfusionIr.
        public let ratio: Double
        /// Pearson correlation of the two band-passed windows (0 when either is flat).
        public let correlation: Double
        /// AC rms / DC of the red channel.
        public let perfusionRed: Double
        /// AC rms / DC of the infrared channel.
        public let perfusionIr: Double
        /// True when the window passes the correlation and perfusion gates and the ratio is finite.
        public let accepted: Bool

        public init(start: Double, ratio: Double, correlation: Double,
                    perfusionRed: Double, perfusionIr: Double, accepted: Bool) {
            self.start = start; self.ratio = ratio; self.correlation = correlation
            self.perfusionRed = perfusionRed; self.perfusionIr = perfusionIr; self.accepted = accepted
        }
    }

    /// The summary of a recording: the median R over its accepted windows.
    public struct Estimate: Equatable, Sendable {
        /// Median R of the accepted windows.
        public let ratio: Double
        public let acceptedWindows: Int
        public let totalWindows: Int
        /// Interquartile range of the accepted ratios; 0 when fewer than 4 windows were accepted.
        public let spread: Double

        public init(ratio: Double, acceptedWindows: Int, totalWindows: Int, spread: Double) {
            self.ratio = ratio; self.acceptedWindows = acceptedWindows
            self.totalWindows = totalWindows; self.spread = spread
        }
    }

    /// Which of two unlabelled pulsatile channels is the red one.
    public enum ChannelOrder: Equatable, Sendable {
        /// The first channel is red, the second infrared.
        case asGiven
        /// The first channel is infrared, the second red.
        case swapped
        /// The physics check cannot tell (not enough clean signal, or both pulse about equally).
        case undetermined
    }

    // MARK: - Dense recordings (tens of Hz up to kHz)

    /// Slide `windowSeconds` windows every `stepSeconds` over a dense red/IR recording and measure R in each.
    /// The whole series is band-passed ONCE (not per window) so the filter has no start-up transient inside
    /// a window except the very first one. DC is the mean of the RAW samples of the window; AC is the
    /// population standard deviation of the band-passed samples. A window whose DC is not a positive finite
    /// number is skipped (a sensor that reads zero or negative has no meaningful ratio). When the two arrays
    /// differ in length the shorter one decides. Returns [] when the sample rate is below `minSampleRateHz`
    /// (or not a finite number) or the series is shorter than one window.
    public static func windows(red: [Double], ir: [Double], sampleRate: Double) -> [Window] {
        guard sampleRate.isFinite, sampleRate >= minSampleRateHz else { return [] }
        let n = min(red.count, ir.count)
        let windowLengthD = (windowSeconds * sampleRate).rounded()
        guard windowLengthD >= 2, windowLengthD <= Double(n) else { return [] }
        let windowLength = Int(windowLengthD)
        let stepD = max(1.0, (stepSeconds * sampleRate).rounded())
        let step = Int(min(stepD, Double(n)))

        let rawRed = Array(red.prefix(n))
        let rawIr = Array(ir.prefix(n))
        let acRed = bandPass(rawRed, sampleRate: sampleRate, low: passBandLowHz, high: passBandHighHz)
        let acIr = bandPass(rawIr, sampleRate: sampleRate, low: passBandLowHz, high: passBandHighHz)

        var out: [Window] = []
        for first in stride(from: 0, through: n - windowLength, by: step) {
            let span = first..<(first + windowLength)
            let dcRed = mean(rawRed, span)
            let dcIr = mean(rawIr, span)
            guard dcRed.isFinite, dcIr.isFinite, dcRed > 0, dcIr > 0 else { continue }

            let (acMeanRed, acSdRed) = meanAndSd(acRed, span)
            let (acMeanIr, acSdIr) = meanAndSd(acIr, span)
            let perfusionRed = acSdRed / dcRed
            let perfusionIr = acSdIr / dcIr
            guard perfusionIr != 0 else { continue }

            let ratio = perfusionRed / perfusionIr
            let correlation = pearson(acRed, meanA: acMeanRed, sdA: acSdRed,
                                      acIr, meanB: acMeanIr, sdB: acSdIr, span)
            let accepted = correlation >= minCorrelation
                && perfusionRange.contains(perfusionIr)
                && ratio.isFinite
            out.append(Window(start: Double(first) / sampleRate, ratio: ratio, correlation: correlation,
                              perfusionRed: perfusionRed, perfusionIr: perfusionIr, accepted: accepted))
        }
        return out
    }

    /// The recording's R: the median over the accepted windows (robust to the odd motion-struck window),
    /// with the interquartile range of those windows as an honest spread. nil when fewer than
    /// `minAcceptedWindows` windows pass the gates; an uncertain number is not reported.
    public static func estimate(red: [Double], ir: [Double], sampleRate: Double) -> Estimate? {
        let all = windows(red: red, ir: ir, sampleRate: sampleRate)
        let ratios = all.filter { $0.accepted }.map { $0.ratio }
        guard ratios.count >= minAcceptedWindows else { return nil }
        let sorted = ratios.sorted()
        let spread: Double
        if sorted.count >= 4 {
            spread = quantile(sorted, 0.75) - quantile(sorted, 0.25)
        } else {
            spread = 0
        }
        return Estimate(ratio: quantile(sorted, 0.5), acceptedWindows: sorted.count,
                        totalWindows: all.count, spread: spread)
    }

    // MARK: - One value per second

    /// R from a recording that banks ONE red/IR pair per second (for example the WHOOP 4.0 v24 record). At
    /// 1 Hz the cardiac pulse (about 0.7-3 Hz) aliases to anywhere in 0-0.5 Hz, so no band-pass can isolate
    /// it. Instead the slow baseline is taken out with a centred moving median of `secondSampleMedianSpan`
    /// samples (edge-padded with the first and last value) and R is the ratio of the residual spreads, each
    /// over its own mean:
    ///
    ///     R = (std(resRed) / mean(red)) / (std(resIr) / mean(ir))
    ///
    /// The median is affine-equivariant, so for red = DCr (1 + PIr s) and ir = DCi (1 + PIi s), with the same
    /// pulse s in both, each residual is its channel's DC times its PI times the SAME function of s and the
    /// ratio is exactly PIr / PIi, whatever the heart rate or the aliased frequency. The method's weakness is
    /// a common-mode wobble that the median does not follow (anything between roughly 0.1 and 0.5 Hz): it
    /// adds an equal relative residual to both channels and pulls R towards 1, which is why the caller should
    /// slice into windows and keep only those with a high correlation.
    ///
    /// The whole input is ONE window (the caller slices it; `secondSampleWindow` samples at least). When the
    /// arrays differ in length the shorter decides. Returns the ratio and the Pearson correlation of the two
    /// residuals, or nil when there are too few samples, a mean is not a positive finite number, or the IR
    /// residual is flat (no pulse to measure against).
    public static func secondSampleRatio(red: [Double], ir: [Double]) -> (ratio: Double, correlation: Double)? {
        let n = min(red.count, ir.count)
        guard n >= secondSampleWindow else { return nil }
        let rawRed = Array(red.prefix(n))
        let rawIr = Array(ir.prefix(n))
        let whole = 0..<n
        let dcRed = mean(rawRed, whole)
        let dcIr = mean(rawIr, whole)
        guard dcRed.isFinite, dcIr.isFinite, dcRed > 0, dcIr > 0 else { return nil }

        let residualRed = movingMedianResidual(rawRed, span: secondSampleMedianSpan)
        let residualIr = movingMedianResidual(rawIr, span: secondSampleMedianSpan)
        let (meanRed, sdRed) = meanAndSd(residualRed, whole)
        let (meanIr, sdIr) = meanAndSd(residualIr, whole)
        guard sdIr > 0 else { return nil }

        let ratio = (sdRed / dcRed) / (sdIr / dcIr)
        guard ratio.isFinite else { return nil }
        let correlation = pearson(residualRed, meanA: meanRed, sdA: sdRed,
                                  residualIr, meanB: meanIr, sdB: sdIr, whole)
        return (ratio: ratio, correlation: correlation)
    }

    // MARK: - Reference curve

    /// The textbook straight-line map from R to a percentage, 110 - 25 R, clamped to 0...100. UNCALIBRATED:
    /// validated only at 94-99 % on finger data (see the header), and a wrist strap's optics will need their
    /// own curve. NOT FOR DISPLAY. A non-finite ratio stays NaN rather than turning into a plausible number.
    public static func genericSpo2(ratio: Double) -> Double {
        let line = 110.0 - 25.0 * ratio
        return min(max(line, 0.0), 100.0)
    }

    // MARK: - Which channel is red?

    /// A physics check for two pulsatile optical channels whose labels cannot be trusted: runs `estimate`
    /// with `a` as red and `b` as infrared. At normal saturation red pulses less than infrared, so R is
    /// below 1. R at most `channelOrderMargin` means `a` really is red (`.asGiven`); R at least its inverse
    /// means the labels are swapped (`.swapped`); anything in between, or no estimate at all, is
    /// `.undetermined`. Valid only at normal saturation, and only when the channels carry their TRUE DC: an
    /// analogue front end that subtracts an offset before the ADC breaks AC/DC and with it this test. This is
    /// how the PhysioNet set's swapped labels were caught (in all 22 subjects the file called "red" pulsed
    /// more than the one called "IR").
    public static func channelOrder(_ a: [Double], _ b: [Double], sampleRate: Double) -> ChannelOrder {
        guard let est = estimate(red: a, ir: b, sampleRate: sampleRate) else { return .undetermined }
        if est.ratio <= channelOrderMargin { return .asGiven }
        if est.ratio >= 1.0 / channelOrderMargin { return .swapped }
        return .undetermined
    }

    // MARK: - Filtering

    /// Zero-phase band-pass: the mean is removed, then a 2nd-order Butterworth high-pass at `low` and a
    /// 2nd-order Butterworth low-pass at `min(high, 0.45 * sampleRate)` (RBJ cookbook biquads, Q = 1/sqrt 2),
    /// each run forward and then again over the reversed output so the result has no phase shift (an AC
    /// estimate must not depend on where in the beat the window happens to start). Non-finite samples are
    /// replaced by the previous finite one before filtering, so a single bad sample cannot poison the rest
    /// of an IIR run. Empty or one-sample input, or an unusable band, gives zeros of the same length.
    static func bandPass(_ x: [Double], sampleRate: Double, low: Double, high: Double) -> [Double] {
        let zeros = [Double](repeating: 0, count: x.count)
        guard x.count >= 2, sampleRate.isFinite, sampleRate > 0 else { return zeros }
        let upper = min(high, 0.45 * sampleRate)
        guard low >= 0, low < upper else { return zeros }

        let filled = fillNonFinite(x)
        let centre = mean(filled, 0..<filled.count)
        var y = filled.map { $0 - centre }
        if low > 0 {
            y = Biquad(.highPass, cutoff: low, sampleRate: sampleRate).zeroPhase(y)
        }
        y = Biquad(.lowPass, cutoff: upper, sampleRate: sampleRate).zeroPhase(y)
        return y
    }

    /// One RBJ-cookbook biquad section, Q = 1/sqrt 2 (Butterworth), direct form I.
    private struct Biquad {
        enum Kind { case lowPass, highPass }

        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        init(_ kind: Kind, cutoff: Double, sampleRate: Double) {
            let q = 0.5.squareRoot()
            let w0 = 2.0 * Double.pi * cutoff / sampleRate
            let cosW = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha
            let edge: Double
            switch kind {
            case .lowPass:
                edge = (1.0 - cosW) / 2.0
                b0 = edge / a0; b1 = (1.0 - cosW) / a0; b2 = edge / a0
            case .highPass:
                edge = (1.0 + cosW) / 2.0
                b0 = edge / a0; b1 = -(1.0 + cosW) / a0; b2 = edge / a0
            }
            a1 = (-2.0 * cosW) / a0
            a2 = (1.0 - alpha) / a0
        }

        func run(_ x: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for k in 0..<x.count {
                let x0 = x[k]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                out[k] = y0
                x2 = x1; x1 = x0
                y2 = y1; y1 = y0
            }
            return out
        }

        /// Forward, then again on the reversed output, then reversed back: |H|^2 magnitude, zero phase.
        func zeroPhase(_ x: [Double]) -> [Double] {
            let forward = run(x)
            let backward = run(Array(forward.reversed()))
            return Array(backward.reversed())
        }
    }

    // MARK: - Small numerics

    private static func fillNonFinite(_ x: [Double]) -> [Double] {
        guard x.contains(where: { !$0.isFinite }) else { return x }
        let firstFinite = x.first(where: { $0.isFinite }) ?? 0
        var last = firstFinite
        var out = x
        for k in 0..<out.count {
            if out[k].isFinite { last = out[k] } else { out[k] = last }
        }
        return out
    }

    private static func mean(_ x: [Double], _ span: Range<Int>) -> Double {
        guard !span.isEmpty else { return 0 }
        var sum = 0.0
        for k in span { sum += x[k] }
        return sum / Double(span.count)
    }

    /// Mean and POPULATION standard deviation (divide by n) over `span`, two-pass for accuracy.
    private static func meanAndSd(_ x: [Double], _ span: Range<Int>) -> (Double, Double) {
        guard !span.isEmpty else { return (0, 0) }
        let m = mean(x, span)
        var sumSq = 0.0
        for k in span {
            let d = x[k] - m
            sumSq += d * d
        }
        return (m, (sumSq / Double(span.count)).squareRoot())
    }

    /// Pearson correlation over `span`, given each series' mean and population sd. 0 when either is flat.
    private static func pearson(_ a: [Double], meanA: Double, sdA: Double,
                                _ b: [Double], meanB: Double, sdB: Double,
                                _ span: Range<Int>) -> Double {
        guard !span.isEmpty, sdA > 0, sdB > 0 else { return 0 }
        var sum = 0.0
        for k in span { sum += (a[k] - meanA) * (b[k] - meanB) }
        let r = sum / (Double(span.count) * sdA * sdB)
        return min(max(r, -1.0), 1.0)
    }

    /// Linear-interpolation quantile of an ascending array (the NumPy default), `p` in 0...1.
    private static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        guard let only = sorted.first else { return 0 }
        guard sorted.count > 1 else { return only }
        let pos = p * Double(sorted.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let frac = pos - Double(lower)
        return sorted[lower] + frac * (sorted[upper] - sorted[lower])
    }

    /// x minus its centred moving median of `span` samples (odd), the ends padded with the first and last
    /// value. The slow baseline goes; whatever the median cannot follow stays in the residual.
    private static func movingMedianResidual(_ x: [Double], span: Int) -> [Double] {
        let n = x.count
        guard n > 0, span > 1 else { return x.map { _ in 0 } }
        let half = span / 2
        var neighbourhood = [Double](repeating: 0, count: span)
        var out = [Double](repeating: 0, count: n)
        for k in 0..<n {
            for j in 0..<span {
                let index = min(max(k + j - half, 0), n - 1)
                neighbourhood[j] = x[index]
            }
            neighbourhood.sort()
            out[k] = x[k] - neighbourhood[half]
        }
        return out
    }
}
