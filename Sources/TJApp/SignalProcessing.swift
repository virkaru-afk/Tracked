import Foundation
import Accelerate

/// Savitzky-Golay smoothing and differentiation.
///
/// Chosen over a Kalman filter deliberately. A Kalman filter is adaptive: its
/// gain depends on the covariance history, so the same input processed after
/// a different warm-up produces slightly different output, and a re-analysis
/// of an old clip need not reproduce the original numbers. Savitzky-Golay is
/// a fixed linear convolution — identical input gives bit-identical output,
/// every time, on any device.
///
/// It also preserves peak shape well, which matters because touchdown is
/// detected from a sharp acceleration peak that an aggressive smoother would
/// flatten and delay.
public struct SavitzkyGolay {

    public let windowLength: Int   // must be odd
    public let polynomialOrder: Int

    /// Convolution coefficients for smoothing and for each derivative order.
    private let coefficients: [[Double]]

    public init(windowLength: Int, polynomialOrder: Int, maxDerivative: Int = 2) {
        precondition(windowLength % 2 == 1, "Window length must be odd")
        precondition(polynomialOrder < windowLength,
                     "Polynomial order must be less than window length")
        self.windowLength = windowLength
        self.polynomialOrder = polynomialOrder
        self.coefficients = Self.computeCoefficients(
            windowLength: windowLength,
            polynomialOrder: polynomialOrder,
            maxDerivative: maxDerivative)
    }

    /// Build coefficients by solving the normal equations of the local
    /// polynomial fit.
    ///
    /// The design matrix A has rows [1, z, z^2, ...] for z = -h ... h. The
    /// filter coefficients for derivative d are row d of (A^T A)^-1 A^T,
    /// scaled by d! to convert the polynomial coefficient into a derivative.
    private static func computeCoefficients(windowLength: Int,
                                            polynomialOrder: Int,
                                            maxDerivative: Int) -> [[Double]] {
        let half = windowLength / 2
        let n = polynomialOrder + 1

        // A: windowLength x n
        var A = [[Double]](repeating: [Double](repeating: 0, count: n),
                           count: windowLength)
        for (i, z) in (-half...half).enumerated() {
            var power = 1.0
            for j in 0..<n {
                A[i][j] = power
                power *= Double(z)
            }
        }

        // AtA = A^T A
        var AtA = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                var sum = 0.0
                for k in 0..<windowLength { sum += A[k][i] * A[k][j] }
                AtA[i][j] = sum
            }
        }

        let AtAInv = invert(AtA, size: n)

        var result = [[Double]]()
        for d in 0...min(maxDerivative, polynomialOrder) {
            var coeffs = [Double](repeating: 0, count: windowLength)
            for k in 0..<windowLength {
                var sum = 0.0
                for j in 0..<n { sum += AtAInv[d][j] * A[k][j] }
                coeffs[k] = sum
            }
            // d! converts the fitted polynomial coefficient to a derivative.
            let factorial = (1...max(d, 1)).reduce(1, *)
            if d > 0 {
                coeffs = coeffs.map { $0 * Double(factorial) }
            }
            result.append(coeffs)
        }
        return result
    }

    private static func invert(_ matrix: [[Double]], size n: Int) -> [[Double]] {
        var a = matrix
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { inv[i][i] = 1 }

        for col in 0..<n {
            // Partial pivoting for numerical stability: the Vandermonde-like
            // normal equations are poorly conditioned for larger windows.
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            if pivot != col {
                a.swapAt(col, pivot)
                inv.swapAt(col, pivot)
            }

            let d = a[col][col]
            guard abs(d) > 1e-14 else { continue }
            for j in 0..<n {
                a[col][j] /= d
                inv[col][j] /= d
            }
            for r in 0..<n where r != col {
                let factor = a[r][col]
                guard factor != 0 else { continue }
                for j in 0..<n {
                    a[r][j] -= factor * a[col][j]
                    inv[r][j] -= factor * inv[col][j]
                }
            }
        }
        return inv
    }

    /// Apply the filter.
    ///
    /// - Parameters:
    ///   - values: uniformly sampled input.
    ///   - derivative: 0 smooths, 1 gives first derivative, 2 second.
    ///   - sampleInterval: seconds between samples, used to scale derivatives
    ///     into per-second units.
    public func apply(_ values: [Double],
                      derivative: Int = 0,
                      sampleInterval: Double = 1.0) -> [Double] {
        guard values.count >= windowLength, derivative < coefficients.count else {
            return derivative == 0 ? values
                                   : [Double](repeating: 0, count: values.count)
        }

        let coeffs = coefficients[derivative]
        let half = windowLength / 2
        let scale = pow(1.0 / sampleInterval, Double(derivative))
        var output = [Double](repeating: 0, count: values.count)

        for i in 0..<values.count {
            var sum = 0.0
            for (k, c) in coeffs.enumerated() {
                // Edge handling by clamped extension. Reflection would create
                // artificial symmetry at the boundary, which for a velocity
                // signal forces the derivative toward zero exactly where the
                // approach run is fastest.
                let idx = min(max(i - half + k, 0), values.count - 1)
                sum += c * values[idx]
            }
            output[i] = sum * scale
        }
        return output
    }
}

/// Processing timebase.
///
/// Every session is resampled onto a regular grid before analysis, regardless
/// of what the camera actually delivered. Real capture is never exactly
/// nominal: a "240 fps" recording arrives at 238.9 fps with occasional
/// duplicated or dropped frames, and those irregularities vary session to
/// session. Filtering on the raw timestamps would therefore apply a slightly
/// different effective smoothing each time. Resampling to a canonical grid
/// means the filter window always spans the same real duration, so two
/// recordings of identical performances produce identical numbers.
///
/// **The grid rate is not a single global constant — it is set once per
/// analysis run, from that recording's own measured frame rate.** An earlier
/// version fixed it at 150 Hz, chosen to sit between the two rates this app
/// actually sees. That was wrong: iPhone slow-motion capture is quantised to
/// 120 or 240 fps, nothing in between, and `ConsistencyGuard` accepts
/// recordings down to 120 fps. A 120 fps recording resampled onto a fixed
/// 150 Hz grid is upsampled by 25% — inventing one sample in five — which
/// directly contradicts the "never upsample" rule this type exists to
/// enforce. There is no fixed rate both real modes can be downsampled to.
///
/// Per-run configuration fixes that and does better than the old fixed rate
/// besides: a 240 fps recording now analyses at up to 240 Hz instead of being
/// thrown away down to 150, which is real extra precision on contact timing
/// exactly when the hardware provided it — a 4.2 ms grid instead of 6.7 ms.
/// A 120 fps recording analyses at its own native 120 Hz: never upsampled,
/// because a recording is never asked to produce more temporal detail than
/// it captured.
///
/// This does **not** reopen the comparability question. Two sessions are
/// already gated on `ComparabilityKey.measuredFrameRate` matching within
/// tolerance before `TrendAnalyser` will compare them — a 120 fps session was
/// already refused against a 240 fps one. This change makes the analysis
/// grid honest about a distinction the comparability gate already enforced.
///
/// `analysisRate` is a shared mutable value, not a parameter threaded through
/// every call — `Window.samples(milliseconds:)` and the three filter
/// builders below all read it live, and changing one number here is what
/// makes every one of them pick up the new rate together. That trades away
/// safety under concurrent analyses: two recordings analysed at once would
/// race on this value. The app only ever runs one analysis at a time today
/// (`AnalysisRunner` is called serially from a single recording or a single
/// correction screen), so this is a real constraint, not a theoretical one —
/// if a background analysis queue is built, this must become an explicit
/// parameter on `Reconstructor`, `EventDetector` and `MetricsEngine` instead.
public struct ProcessingTimebase: Sendable {

    /// The floor every supported capture mode can honestly reach without
    /// upsampling: 1080p120 is the lowest frame rate this app records at.
    /// Used before any session-specific rate has been configured — at
    /// startup, and anywhere the UI needs a number with no session in hand.
    public static let safeDefaultRate: Double = 120.0

    /// The ceiling. Higher buys sharper event boundaries only up to the
    /// point where pose-model noise dominates; validation found no benefit
    /// resampling past the sensor's own 240 fps ceiling, so nothing above it
    /// is worth carrying through the pipeline.
    public static let maximumUsefulRate: Double = 240.0

    public private(set) static var analysisRate: Double = safeDefaultRate
    public static var sampleInterval: Double { 1.0 / analysisRate }

    /// The rate a delivered frame rate clamps to, as a pure function with no
    /// dependency on the mutable `analysisRate`.
    ///
    /// Exists separately from `configure(forDeliveredRate:)` so a caller that
    /// needs to reconstruct *what the rate must have been* for an analysis
    /// that already ran — `SessionAnalysis.analysisFrameIndex(forTime:)`,
    /// reconstructing a past session's grid from its stored
    /// `measuredFrameRate` — can compute it directly, rather than reading
    /// today's `analysisRate` and getting whatever some unrelated, more
    /// recent analysis last left it at.
    public static func clampedRate(forDelivered delivered: Double) -> Double {
        min(max(delivered, safeDefaultRate), maximumUsefulRate)
    }

    /// Set the grid rate for the analysis about to run, from that
    /// recording's measured delivered frame rate.
    ///
    /// Clamped, never trusted blindly: `delivered` comes from counting real
    /// sample-buffer timestamps and can in principle be anything, so this
    /// still enforces the two invariants that matter regardless of what the
    /// camera claims — never above what was actually captured (no
    /// upsampling), never below the accepted floor (no degrading a
    /// perfectly good 120 fps recording because of one low reading).
    @discardableResult
    public static func configure(forDeliveredRate delivered: Double) -> Double {
        let rate = clampedRate(forDelivered: delivered)
        analysisRate = rate
        return rate
    }

    /// Smoothing windows specified in milliseconds, then converted to
    /// samples. Specifying in time rather than frames is what makes the
    /// effective smoothing independent of capture rate.
    public enum Window {
        /// Position smoothing: light, to avoid rounding off the sharp
        /// transition at touchdown.
        public static let positionMilliseconds: Double = 33.3
        /// Velocity needs more support than position.
        public static let velocityMilliseconds: Double = 53.3
        /// Acceleration is the noisiest derivative and needs the most.
        public static let accelerationMilliseconds: Double = 80.0

        public static func samples(milliseconds: Double) -> Int {
            let n = Int((milliseconds / 1000.0 * analysisRate).rounded())
            return n % 2 == 0 ? n + 1 : max(n, 5)
        }
    }

    public static var positionFilter: SavitzkyGolay {
        SavitzkyGolay(windowLength: Window.samples(milliseconds: Window.positionMilliseconds),
                      polynomialOrder: 2)
    }

    public static var velocityFilter: SavitzkyGolay {
        SavitzkyGolay(windowLength: Window.samples(milliseconds: Window.velocityMilliseconds),
                      polynomialOrder: 2)
    }

    public static var accelerationFilter: SavitzkyGolay {
        SavitzkyGolay(windowLength: Window.samples(milliseconds: Window.accelerationMilliseconds),
                      polynomialOrder: 3)
    }
}

/// Resamples irregular timestamped samples onto the canonical grid.
public struct Resampler {

    /// Linear interpolation onto a uniform grid.
    ///
    /// Linear rather than cubic: cubic interpolation overshoots near the
    /// sharp velocity discontinuity at touchdown, manufacturing a small
    /// pre-impact dip that the event detector would misread. Linear is
    /// slightly lossier in smooth regions and considerably safer at exactly
    /// the moments being measured.
    public static func resample(timestamps: [Double],
                                values: [Double],
                                toGrid grid: [Double]) -> [Double] {
        guard timestamps.count == values.count, timestamps.count >= 2 else {
            return [Double](repeating: values.first ?? 0, count: grid.count)
        }

        var output = [Double](repeating: 0, count: grid.count)
        var searchIndex = 0

        for (i, t) in grid.enumerated() {
            if t <= timestamps[0] { output[i] = values[0]; continue }
            if t >= timestamps[timestamps.count - 1] {
                output[i] = values[values.count - 1]; continue
            }
            while searchIndex < timestamps.count - 2 && timestamps[searchIndex + 1] < t {
                searchIndex += 1
            }
            let t0 = timestamps[searchIndex], t1 = timestamps[searchIndex + 1]
            let span = t1 - t0
            let alpha = span > 1e-12 ? (t - t0) / span : 0
            output[i] = values[searchIndex] * (1 - alpha)
                      + values[searchIndex + 1] * alpha
        }
        return output
    }

    /// Build the canonical grid covering a set of timestamps.
    public static func grid(from start: Double, to end: Double) -> [Double] {
        let interval = ProcessingTimebase.sampleInterval
        let count = max(Int(((end - start) / interval).rounded()) + 1, 1)
        return (0..<count).map { start + Double($0) * interval }
    }
}
