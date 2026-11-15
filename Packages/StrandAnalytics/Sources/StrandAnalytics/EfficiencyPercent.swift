import Foundation

/// Sleep efficiency arrives in two scales: 0-100 (the engine, WHOOP exports) and 0-1 (some imports and
/// widgets). Printing a 0-1 fraction through a percent format reads "1 %". Every place that prints
/// efficiency normalises through here first.
public enum EfficiencyPercent {
    /// The value as a percentage 0...100. A value of 1.0 or less is read as a fraction (0.92 -> 92).
    /// Negative and non-finite input has no meaning and returns nil.
    public static func percent(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value <= 1.0 ? value * 100.0 : value
    }
}
