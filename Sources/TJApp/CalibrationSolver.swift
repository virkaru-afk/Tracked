import Foundation
import simd

/// The pixel observations a user provides during calibration.
public struct CalibrationObservations: Codable, Equatable, Sendable {

    /// Four board corners, in the canonical order defined by `WorldFrame`.
    public var boardCorners: [SIMD2<Double>]

    /// Base of the reference pipe where it meets the ground.
    public var pipeBase: SIMD2<Double>

    /// Centre of the marker at the top of the reference pipe.
    public var pipeTop: SIMD2<Double>

    /// Tripod height measured with a tape, in metres. Used as a soft prior:
    /// it steers the solve without overriding what the image actually shows.
    public var measuredTripodHeight: Double

    /// Uncertainty on that tape measurement. 20 mm reflects what someone can
    /// realistically achieve measuring from ground to the sensor line.
    public var tripodHeightUncertainty: Double

    public init(boardCorners: [SIMD2<Double>],
                pipeBase: SIMD2<Double>,
                pipeTop: SIMD2<Double>,
                measuredTripodHeight: Double,
                tripodHeightUncertainty: Double = 0.020) {
        self.boardCorners = boardCorners
        self.pipeBase = pipeBase
        self.pipeTop = pipeTop
        self.measuredTripodHeight = measuredTripodHeight
        self.tripodHeightUncertainty = tripodHeightUncertainty
    }

    private enum CodingKeys: String, CodingKey {
        case cornersX, cornersY, pipeBaseX, pipeBaseY, pipeTopX, pipeTopY
        case measuredTripodHeight, tripodHeightUncertainty
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let xs = try c.decode([Double].self, forKey: .cornersX)
        let ys = try c.decode([Double].self, forKey: .cornersY)
        boardCorners = zip(xs, ys).map { SIMD2($0, $1) }
        pipeBase = SIMD2(try c.decode(Double.self, forKey: .pipeBaseX),
                         try c.decode(Double.self, forKey: .pipeBaseY))
        pipeTop = SIMD2(try c.decode(Double.self, forKey: .pipeTopX),
                        try c.decode(Double.self, forKey: .pipeTopY))
        measuredTripodHeight = try c.decode(Double.self, forKey: .measuredTripodHeight)
        tripodHeightUncertainty = try c.decode(Double.self, forKey: .tripodHeightUncertainty)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(boardCorners.map(\.x), forKey: .cornersX)
        try c.encode(boardCorners.map(\.y), forKey: .cornersY)
        try c.encode(pipeBase.x, forKey: .pipeBaseX)
        try c.encode(pipeBase.y, forKey: .pipeBaseY)
        try c.encode(pipeTop.x, forKey: .pipeTopX)
        try c.encode(pipeTop.y, forKey: .pipeTopY)
        try c.encode(measuredTripodHeight, forKey: .measuredTripodHeight)
        try c.encode(tripodHeightUncertainty, forKey: .tripodHeightUncertainty)
    }
}

public struct CalibrationResult: Sendable {
    public let pose: CameraPose
    /// RMS reprojection error over the six reference points, in pixels.
    public let reprojectionRMSE: Double
    /// Worst single-point reprojection error, in pixels. Catches one badly
    /// mistapped corner that a mean would hide.
    public let maxPointError: Double
    /// Per-point errors, in the same order as the observations, so the UI can
    /// highlight exactly which tap to redo.
    public let pointErrors: [Double]
    public let iterations: Int
    public let converged: Bool
}

public enum CalibrationError: Error, LocalizedError {
    case wrongCornerCount(Int)
    case didNotConverge
    case degenerateGeometry(String)

    public var errorDescription: String? {
        switch self {
        case .wrongCornerCount(let n):
            return "Expected 4 board corners, received \(n)."
        case .didNotConverge:
            return "Calibration did not converge. Re-tap the reference points."
        case .degenerateGeometry(let detail):
            return "Calibration geometry is degenerate: \(detail)"
        }
    }
}

/// Solves for camera pose from tapped reference points.
///
/// Four free parameters: distance, height, yaw, pitch, against twelve pixel
/// residuals plus one prior residual. Yaw and pitch are free because tripod
/// alignment error is unavoidable in the field and, if left unmodelled, is
/// absorbed into the distance estimate as a systematic bias — roughly 94 mm
/// per degree of misalignment in validation. Letting them float costs about
/// 18% extra variance and removes that bias entirely.
public struct CalibrationSolver {

    public struct Options: Sendable {
        public var maxIterations: Int = 100
        public var parameterTolerance: Double = 1e-10
        public var costTolerance: Double = 1e-12
        public var initialDistance: Double = 3.5
        public var initialDamping: Double = 1e-3
        public init() {}
    }

    public let intrinsics: CameraIntrinsics
    public let pipe: ReferencePipe
    public let options: Options

    public init(intrinsics: CameraIntrinsics,
                pipe: ReferencePipe = ReferencePipe(),
                options: Options = Options()) {
        self.intrinsics = intrinsics
        self.pipe = pipe
        self.options = options
    }

    /// World points in the same order the residual vector uses.
    private func referenceWorldPoints() -> [SIMD3<Double>] {
        WorldFrame.boardCorners + [pipe.basePosition, pipe.topPosition]
    }

    private func observedPixels(_ obs: CalibrationObservations) -> [SIMD2<Double>] {
        obs.boardCorners + [obs.pipeBase, obs.pipeTop]
    }

    /// Residual vector: 12 pixel residuals followed by 1 scaled prior residual.
    private func residuals(parameters p: SIMD4<Double>,
                           observations obs: CalibrationObservations) -> [Double] {
        let pose = CameraPose(distance: p[0], height: p[1], yaw: p[2], pitch: p[3])
        let model = CameraModel(intrinsics: intrinsics, pose: pose)
        let world = referenceWorldPoints()
        let observed = observedPixels(obs)

        var r = [Double]()
        r.reserveCapacity(13)

        for (w, o) in zip(world, observed) {
            if let projected = model.project(w) {
                r.append(projected.x - o.x)
                r.append(projected.y - o.y)
            } else {
                // Point fell behind the camera: a large but finite penalty
                // steers the optimiser back without producing a NaN that
                // would poison the whole solve.
                r.append(1e4)
                r.append(1e4)
            }
        }

        // Soft prior on tripod height, scaled into pixel-equivalent units so
        // it carries comparable weight to the reprojection terms.
        r.append((p[1] - obs.measuredTripodHeight) / obs.tripodHeightUncertainty)

        return r
    }

    /// Numeric Jacobian by central differences.
    ///
    /// Central rather than forward differences: the extra evaluations are
    /// irrelevant at this problem size, and the improved accuracy matters
    /// because pitch and yaw are weakly separated from height near the
    /// solution, where a sloppy Jacobian slows or stalls convergence.
    private func jacobian(parameters p: SIMD4<Double>,
                          observations obs: CalibrationObservations,
                          residualCount m: Int) -> [[Double]] {
        let steps = SIMD4<Double>(1e-6, 1e-6, 1e-7, 1e-7)
        var J = Array(repeating: Array(repeating: 0.0, count: 4), count: m)

        for j in 0..<4 {
            var pf = p, pb = p
            pf[j] += steps[j]
            pb[j] -= steps[j]
            let rf = residuals(parameters: pf, observations: obs)
            let rb = residuals(parameters: pb, observations: obs)
            let inv = 1.0 / (2 * steps[j])
            for i in 0..<m {
                J[i][j] = (rf[i] - rb[i]) * inv
            }
        }
        return J
    }

    public func solve(observations obs: CalibrationObservations) throws -> CalibrationResult {
        guard obs.boardCorners.count == 4 else {
            throw CalibrationError.wrongCornerCount(obs.boardCorners.count)
        }

        // A sensible starting height comes free from the tape measurement.
        var p = SIMD4<Double>(options.initialDistance,
                              obs.measuredTripodHeight,
                              0.0, 0.0)

        var lambda = options.initialDamping
        var currentResiduals = residuals(parameters: p, observations: obs)
        var currentCost = currentResiduals.reduce(0) { $0 + $1 * $1 }
        let m = currentResiduals.count
        var iterations = 0
        var converged = false

        for iter in 0..<options.maxIterations {
            iterations = iter + 1
            let J = jacobian(parameters: p, observations: obs, residualCount: m)

            // Normal equations: (J^T J + lambda diag(J^T J)) delta = -J^T r
            var JtJ = simd_double4x4(0)
            var Jtr = SIMD4<Double>(repeating: 0)

            for i in 0..<m {
                let row = SIMD4<Double>(J[i][0], J[i][1], J[i][2], J[i][3])
                for a in 0..<4 {
                    for b in 0..<4 {
                        JtJ[a][b] += row[a] * row[b]
                    }
                    Jtr[a] += row[a] * currentResiduals[i]
                }
            }

            var stepAccepted = false

            // Inner loop adapts damping until a step reduces the cost.
            for _ in 0..<30 {
                var damped = JtJ
                for a in 0..<4 {
                    damped[a][a] += lambda * max(JtJ[a][a], 1e-12)
                }

                let det = damped.determinant
                guard abs(det) > 1e-18 else {
                    lambda *= 10
                    continue
                }

                let delta = -(damped.inverse * Jtr)
                guard delta.x.isFinite, delta.y.isFinite,
                      delta.z.isFinite, delta.w.isFinite else {
                    lambda *= 10
                    continue
                }

                var candidate = p + delta

                // Keep the camera in front of the board and above the ground.
                // These are physical facts, not tuning knobs: a negative
                // distance or a sub-ground camera is never a valid answer.
                candidate[0] = max(candidate[0], 0.5)
                candidate[1] = max(candidate[1], 0.1)

                let candidateResiduals = residuals(parameters: candidate,
                                                   observations: obs)
                let candidateCost = candidateResiduals.reduce(0) { $0 + $1 * $1 }

                if candidateCost < currentCost {
                    let costChange = currentCost - candidateCost
                    let stepSize = simd_length(delta)

                    p = candidate
                    currentResiduals = candidateResiduals
                    currentCost = candidateCost
                    lambda = max(lambda / 10, 1e-12)
                    stepAccepted = true

                    if stepSize < options.parameterTolerance ||
                        costChange < options.costTolerance * max(currentCost, 1e-12) {
                        converged = true
                    }
                    break
                } else {
                    lambda *= 10
                }
            }

            if converged { break }
            if !stepAccepted {
                // Damping ran away without finding a downhill step. If the
                // residuals are already small this is convergence to
                // numerical precision; otherwise it is a genuine failure.
                converged = currentCost < 1.0
                break
            }
        }

        guard converged || currentCost < 100 else {
            throw CalibrationError.didNotConverge
        }

        // Per-point errors from the 12 pixel residuals, ignoring the prior.
        var pointErrors = [Double]()
        for i in 0..<6 {
            let dx = currentResiduals[i * 2]
            let dy = currentResiduals[i * 2 + 1]
            pointErrors.append((dx * dx + dy * dy).squareRoot())
        }

        let sumSquares = pointErrors.reduce(0) { $0 + $1 * $1 }
        let rmse = (sumSquares / Double(pointErrors.count)).squareRoot()

        let pose = CameraPose(distance: p[0], height: p[1], yaw: p[2], pitch: p[3])

        // Sanity check on the recovered geometry. Beyond about 10 m the
        // board's near/far edge separation collapses to a handful of pixels
        // and the solve leans almost entirely on the pipe.
        if pose.distance > 12.0 {
            throw CalibrationError.degenerateGeometry(
                "Recovered camera distance of \(String(format: "%.1f", pose.distance)) m "
                + "is too far for reliable measurement. Move the tripod closer.")
        }

        return CalibrationResult(pose: pose,
                                 reprojectionRMSE: rmse,
                                 maxPointError: pointErrors.max() ?? 0,
                                 pointErrors: pointErrors,
                                 iterations: iterations,
                                 converged: converged)
    }
}
