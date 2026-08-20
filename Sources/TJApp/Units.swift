import Foundation

/// Imperial formatting for display.
///
/// Every measurement in the pipeline is stored, compared and persisted in SI —
/// metres, seconds, metres per second. Nothing below is ever fed back into the
/// analysis. The conversion happens at the last possible moment, in the view
/// layer, for two reasons:
///
/// First, `TrendAnalyser.meaningfulChangeThresholds` is expressed in metres.
/// If sessions were stored in feet the thresholds would have to be converted
/// too, and a rounding difference between the stored value and the threshold
/// would let noise through as "progress" — the one failure this project is
/// built to avoid.
///
/// Second, feet-and-inches is lossy at the precision this tool claims.
/// Rounding a hop to the nearest tenth of an inch discards 1.3 mm, which is
/// half the measured run-to-run SD. Displaying the rounded number is fine;
/// storing it is not.
public enum Imperial {

    public static let inchesPerMetre = 39.37007874015748
    public static let feetPerMetre = 3.280839895013123

    /// Distance as feet and inches, e.g. `17′ 5.4″`.
    ///
    /// Inches carry one decimal by default. That is deliberate: one tenth of
    /// an inch is 2.5 mm, which sits just under the 2.5–2.9 mm run-to-run SD
    /// measured in validation. Showing two decimals would imply a resolution
    /// the measurement does not have.
    public static func feetInches(_ metres: Double,
                                  inchDecimals: Int = 1,
                                  style: Style = .primes) -> String {
        guard metres.isFinite else { return "—" }

        let negative = metres < 0
        let totalInches = abs(metres) * inchesPerMetre

        var feet = Int(totalInches / 12)
        var inches = totalInches - Double(feet) * 12

        // Round first, then carry. Rounding 11.97 to one decimal gives 12.0,
        // which must read as the next foot rather than as `4′ 12.0″`.
        let scale = pow(10.0, Double(inchDecimals))
        inches = (inches * scale).rounded() / scale
        if inches >= 12 {
            inches -= 12
            feet += 1
        }

        let inchText = String(format: "%.\(inchDecimals)f", inches)
        let sign = negative ? "−" : ""

        switch style {
        case .primes:
            return feet == 0
                ? "\(sign)\(inchText)″"
                : "\(sign)\(feet)′ \(inchText)″"
        case .ascii:
            return feet == 0
                ? "\(negative ? "-" : "")\(inchText)in"
                : "\(negative ? "-" : "")\(feet)ft \(inchText)in"
        }
    }

    /// Inches only, for quantities smaller than a foot: board accuracy,
    /// touchdown distance ahead of the hips, session-to-session deltas.
    public static func inches(_ metres: Double, decimals: Int = 1) -> String {
        guard metres.isFinite else { return "—" }
        let value = metres * inchesPerMetre
        return String(format: "%.\(decimals)f″", value)
    }

    /// A signed delta, always with an explicit sign so a comparison column
    /// reads unambiguously.
    public static func signedInches(_ metres: Double, decimals: Int = 1) -> String {
        guard metres.isFinite else { return "—" }
        let value = metres * inchesPerMetre
        let sign = value >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.\(decimals)f", abs(value)))″"
    }

    /// Feet per second, for anyone who wants approach speed in imperial.
    /// Metres per second remains the default: coaching literature on triple
    /// jump approach velocity is in SI, and converting would make published
    /// benchmarks unusable.
    public static func feetPerSecond(_ metresPerSecond: Double) -> String {
        String(format: "%.1f ft/s", metresPerSecond * feetPerMetre)
    }

    public enum Style: Sendable {
        /// `17′ 5.4″` — for on-screen display.
        case primes
        /// `17ft 5.4in` — for CSV export, where prime characters cause
        /// encoding trouble in spreadsheet imports.
        case ascii
    }
}

/// Formatting for the non-distance quantities, kept beside the imperial
/// helpers so every display conversion lives in one file.
public enum Format {

    /// Milliseconds from seconds. Contact and flight times are quoted in ms
    /// throughout the coaching literature and in `meaningfulChangeThresholds`.
    public static func milliseconds(_ seconds: Double, decimals: Int = 0) -> String {
        guard seconds.isFinite else { return "—" }
        return String(format: "%.\(decimals)f ms", seconds * 1000)
    }

    public static func signedMilliseconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let ms = seconds * 1000
        return "\(ms >= 0 ? "+" : "−")\(String(format: "%.0f", abs(ms))) ms"
    }

    public static func velocity(_ metresPerSecond: Double) -> String {
        guard metresPerSecond.isFinite else { return "—" }
        return String(format: "%.2f m/s", metresPerSecond)
    }

    public static func signedVelocity(_ metresPerSecond: Double) -> String {
        guard metresPerSecond.isFinite else { return "—" }
        let sign = metresPerSecond >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.2f", abs(metresPerSecond))) m/s"
    }

    public static func degrees(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f°", value)
    }

    public static func signedDegrees(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(value >= 0 ? "+" : "−")\(String(format: "%.1f", abs(value)))°"
    }

    public static func percent(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(decimals)f%%", value)
    }

    public static func signedPercent(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        let sign = value >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.\(decimals)f", abs(value)))%"
    }

    /// Timecode for the scrubber: `2.340 s`. Milliseconds are shown because
    /// the whole point of the correction screen is placing an event to the
    /// frame, and one frame is 4.2 ms at 240 fps or 8.3 ms at 120 fps —
    /// either way, well inside the third decimal.
    public static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        return String(format: "%.3f s", seconds)
    }
}
