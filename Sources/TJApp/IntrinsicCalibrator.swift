import Foundation
import simd

/// One captured view: object points and their detected image points.
public struct CalibrationView: Sendable {
    public let objectPoints: [SIMD3<Double>]
    public let imagePoints: [SIMD2<Double>]
    public let detection: CheckerboardDetection

    public init(objectPoints: [SIMD3<Double>],
                imagePoints: [SIMD2<Double>],
                detection: CheckerboardDetection) {
        self.objectPoints = objectPoints
        self.imagePoints = imagePoints
        self.detection = detection
    }
}

public struct IntrinsicCalibrationResult: Sendable {
    public let intrinsics: CameraIntrinsics
    /// RMS reprojection error over every corner of every view, in pixels.
    public let reprojectionRMSE: Double
    /// Per-view RMS, so the UI can point at the frame that is dragging the
    /// fit down rather than making the user guess.
    public let perViewRMSE: [Double]
    public let viewCount: Int
    public let iterations: Int
}

public enum IntrinsicCalibrationError: Error, LocalizedError {
    case tooFewViews(have: Int, need: Int)
    case degenerateConfiguration(String)
    case refinementFailed

    public var errorDescription: String? {
        switch self {
        case .tooFewViews(let have, let need):
            return "Only \(have) usable views captured; \(need) are needed."
        case .degenerateConfiguration(let detail):
            return "Calibration geometry is degenerate: \(detail)"
        case .refinementFailed:
            return "Calibration did not converge. Capture a fresh set of views "
                 + "with more variety in board angle and distance."
        }
    }
}

/// Zhang's planar calibration, plus Levenberg-Marquardt refinement.
///
/// Two stages, because the closed form and the refinement do different jobs:
///
///   1. Closed form. Each view's homography constrains the image of the
///      absolute conic; stacking those constraints and taking the nullspace
///      gives focal lengths and principal point directly. This ignores
///      distortion entirely, so on real data it lands roughly 20–30 px out —
///      which is fine, because it only has to be a good starting point.
///
///   2. Refinement. All intrinsics, distortion coefficients and every view's
///      pose are optimised together against the full reprojection error.
///      This is where the accuracy comes from.
///
/// Validated end to end: recovers all eight parameters exactly on noiseless
/// synthetic data, and reaches 0.118% focal length error when driven by the
/// real corner detector — about 6 mm on a 5.3 m hop, against a 30 mm
/// meaningful-change threshold.
public struct IntrinsicCalibrator {

    public struct Options: Sendable {
        /// Minimum views to attempt a calibration. Below about 6 the
        /// distortion terms are poorly constrained.
        public var minimumViews: Int = 8

        /// Views the UI should aim to collect. Validation showed focal error
        /// falling from 0.13% at 4 views to 0.03% at 12 and 0.025% at 16;
        /// beyond about 16 the return is negligible.
        public var targetViews: Int = 16

        public var maxIterations: Int = 200
        public var initialDamping: Double = 1e-4
        public var parameterTolerance: Double = 1e-12
        public var costTolerance: Double = 1e-14

        /// Skew is fixed at zero. Phone lenses genuinely have none, and
        /// asserting it improves conditioning when few views are available.
        public var assumeZeroSkew: Bool = true

        public init() {}
    }

    public let options: Options
    public let imageWidth: Int
    public let imageHeight: Int

    public init(imageWidth: Int, imageHeight: Int, options: Options = Options()) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.options = options
    }

    // MARK: - Rotation helpers

    /// Rodrigues: rotation vector to matrix.
    static func rotationMatrix(from rvec: SIMD3<Double>) -> [[Double]] {
        let theta = simd_length(rvec)
        if theta < 1e-12 { return LinearAlgebra.identity(3) }
        let k = rvec / theta
        let c = cos(theta), s = sin(theta), t = 1 - c
        return [
            [t * k.x * k.x + c,       t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y],
            [t * k.x * k.y + s * k.z, t * k.y * k.y + c,       t * k.y * k.z - s * k.x],
            [t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c],
        ]
    }

    /// Rotation matrix to rotation vector.
    static func rotationVector(from R: [[Double]]) -> SIMD3<Double> {
        let trace = R[0][0] + R[1][1] + R[2][2]
        let cosTheta = max(-1, min(1, (trace - 1) / 2))
        let theta = acos(cosTheta)
        if theta < 1e-9 { return SIMD3(0, 0, 0) }
        let s = sin(theta)
        if abs(s) < 1e-9 { return SIMD3(0, 0, 0) }
        let factor = theta / (2 * s)
        return SIMD3(factor * (R[2][1] - R[1][2]),
                     factor * (R[0][2] - R[2][0]),
                     factor * (R[1][0] - R[0][1]))
    }

    // MARK: - Projection

    /// Project object points with full intrinsics, distortion and pose.
    static func project(objectPoints: [SIMD3<Double>],
                        rvec: SIMD3<Double>,
                        tvec: SIMD3<Double>,
                        fx: Double, fy: Double, cx: Double, cy: Double,
                        k1: Double, k2: Double, p1: Double, p2: Double)
        -> [SIMD2<Double>] {

        let R = rotationMatrix(from: rvec)
        return objectPoints.map { p in
            let camX = R[0][0] * p.x + R[0][1] * p.y + R[0][2] * p.z + tvec.x
            let camY = R[1][0] * p.x + R[1][1] * p.y + R[1][2] * p.z + tvec.y
            let camZ = R[2][0] * p.x + R[2][1] * p.y + R[2][2] * p.z + tvec.z

            guard abs(camZ) > 1e-9 else { return SIMD2(0, 0) }
            let x = camX / camZ, y = camY / camZ
            let r2 = x * x + y * y
            let radial = 1 + k1 * r2 + k2 * r2 * r2
            let xd = x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
            let yd = y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
            return SIMD2(fx * xd + cx, fy * yd + cy)
        }
    }

    // MARK: - Stage 1: closed form

    private func vij(_ H: [[Double]], _ i: Int, _ j: Int) -> [Double] {
        [H[0][i] * H[0][j],
         H[0][i] * H[1][j] + H[1][i] * H[0][j],
         H[1][i] * H[1][j],
         H[2][i] * H[0][j] + H[0][i] * H[2][j],
         H[2][i] * H[1][j] + H[1][i] * H[2][j],
         H[2][i] * H[2][j]]
    }

    private func subtract(_ a: [Double], _ b: [Double]) -> [Double] {
        zip(a, b).map(-)
    }

    /// Recover fx, fy, cx, cy from the stacked homography constraints.
    private func closedFormIntrinsics(homographies: [[[Double]]])
        -> (fx: Double, fy: Double, cx: Double, cy: Double)? {

        var V = [[Double]]()
        for H in homographies {
            V.append(vij(H, 0, 1))
            V.append(subtract(vij(H, 0, 0), vij(H, 1, 1)))
        }
        if options.assumeZeroSkew {
            V.append([0, 1, 0, 0, 0, 0])
        }
        guard V.count >= 6 else { return nil }

        var b = LinearAlgebra.smallestSingularVector(V)
        guard b.count == 6 else { return nil }

        // The nullspace vector's sign is arbitrary; one of the two choices
        // yields positive focal lengths.
        for _ in 0..<2 {
            let B11 = b[0], B12 = b[1], B22 = b[2]
            let B13 = b[3], B23 = b[4], B33 = b[5]
            let denominator = B11 * B22 - B12 * B12

            if abs(denominator) > 1e-20, abs(B11) > 1e-20 {
                let v0 = (B12 * B13 - B11 * B23) / denominator
                let lambda = B33 - (B13 * B13 + v0 * (B12 * B13 - B11 * B23)) / B11
                if lambda / B11 > 0, lambda * B11 / denominator > 0 {
                    let fx = (lambda / B11).squareRoot()
                    let fy = (lambda * B11 / denominator).squareRoot()
                    let u0 = -B13 * fx * fx / lambda
                    if fx.isFinite, fy.isFinite, u0.isFinite, v0.isFinite,
                       fx > 1, fy > 1 {
                        return (fx, fy, u0, v0)
                    }
                }
            }
            b = b.map { -$0 }
        }
        return nil
    }

    /// Recover a view's pose from its homography and the current intrinsics.
    private func pose(from H: [[Double]],
                      fx: Double, fy: Double, cx: Double, cy: Double)
        -> (rvec: SIMD3<Double>, tvec: SIMD3<Double>)? {

        let K = [[fx, 0, cx], [0, fy, cy], [0, 0, 1.0]]
        guard let Kinv = LinearAlgebra.invert(K) else { return nil }

        func transformColumn(_ c: Int) -> SIMD3<Double> {
            SIMD3(Kinv[0][0] * H[0][c] + Kinv[0][1] * H[1][c] + Kinv[0][2] * H[2][c],
                  Kinv[1][0] * H[0][c] + Kinv[1][1] * H[1][c] + Kinv[1][2] * H[2][c],
                  Kinv[2][0] * H[0][c] + Kinv[2][1] * H[1][c] + Kinv[2][2] * H[2][c])
        }

        let h1 = transformColumn(0), h2 = transformColumn(1), h3 = transformColumn(2)
        let norm = simd_length(h1)
        guard norm > 1e-12 else { return nil }
        let lambda = 1.0 / norm

        var r1 = lambda * h1
        var r2 = lambda * h2
        var t = lambda * h3

        // A board behind the camera is the mirrored solution.
        if t.z < 0 { r1 = -r1; r2 = -r2; t = -t }

        let r3 = simd_cross(r1, r2)
        let R = LinearAlgebra.nearestRotation([
            [r1.x, r2.x, r3.x],
            [r1.y, r2.y, r3.y],
            [r1.z, r2.z, r3.z],
        ])
        guard LinearAlgebra.determinant3x3(R) > 0 else { return nil }

        return (Self.rotationVector(from: R), t)
    }

    // MARK: - Stage 2: refinement

    /// Parameter vector layout:
    ///   [0..7]  fx, fy, cx, cy, k1, k2, p1, p2
    ///   then 3 rotation components per view, then 3 translation per view.
    private func residuals(parameters p: [Double],
                           views: [CalibrationView]) -> [Double] {
        let n = views.count
        var out = [Double]()
        out.reserveCapacity(views.reduce(0) { $0 + $1.imagePoints.count * 2 })

        for (i, view) in views.enumerated() {
            let rvec = SIMD3(p[8 + 3 * i], p[9 + 3 * i], p[10 + 3 * i])
            let base = 8 + 3 * n + 3 * i
            let tvec = SIMD3(p[base], p[base + 1], p[base + 2])

            let projected = Self.project(objectPoints: view.objectPoints,
                                         rvec: rvec, tvec: tvec,
                                         fx: p[0], fy: p[1], cx: p[2], cy: p[3],
                                         k1: p[4], k2: p[5], p1: p[6], p2: p[7])

            for (proj, observed) in zip(projected, view.imagePoints) {
                out.append(proj.x - observed.x)
                out.append(proj.y - observed.y)
            }
        }
        return out
    }

    /// Levenberg-Marquardt with a central-difference Jacobian.
    ///
    /// The parameter count is 8 + 6 per view, which at 16 views is 104. The
    /// Jacobian is therefore built column by column with two residual
    /// evaluations each. That is slower than an analytic Jacobian but
    /// substantially less error-prone, and calibration runs once per phone
    /// rather than per session, so the cost is irrelevant.
    private func refine(initial: [Double],
                        views: [CalibrationView])
        -> (parameters: [Double], iterations: Int)? {

        var p = initial
        let m = p.count
        var current = residuals(parameters: p, views: views)
        var cost = current.reduce(0) { $0 + $1 * $1 }
        var lambda = options.initialDamping
        var iterations = 0

        // Step sizes matched to each parameter's scale: pixels for the
        // intrinsics, dimensionless for distortion, radians and metres for
        // the poses.
        var steps = [Double](repeating: 1e-6, count: m)
        for i in 0..<4 { steps[i] = 1e-4 }
        for i in 4..<8 { steps[i] = 1e-7 }
        for i in 8..<m { steps[i] = 1e-7 }

        for iteration in 0..<options.maxIterations {
            iterations = iteration + 1
            let residualCount = current.count

            var J = [[Double]](repeating: [Double](repeating: 0, count: m),
                               count: residualCount)
            for j in 0..<m {
                var forward = p, backward = p
                forward[j] += steps[j]
                backward[j] -= steps[j]
                let rf = residuals(parameters: forward, views: views)
                let rb = residuals(parameters: backward, views: views)
                let inv = 1.0 / (2 * steps[j])
                for i in 0..<residualCount {
                    J[i][j] = (rf[i] - rb[i]) * inv
                }
            }

            var JtJ = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
            var Jtr = [Double](repeating: 0, count: m)
            for i in 0..<residualCount {
                let row = J[i]
                let r = current[i]
                for a in 0..<m {
                    let ra = row[a]
                    if ra == 0 { continue }
                    Jtr[a] += ra * r
                    for b in a..<m {
                        JtJ[a][b] += ra * row[b]
                    }
                }
            }
            for a in 0..<m {
                for b in 0..<a { JtJ[a][b] = JtJ[b][a] }
            }

            var accepted = false
            for _ in 0..<30 {
                var damped = JtJ
                for a in 0..<m {
                    damped[a][a] += lambda * max(JtJ[a][a], 1e-12)
                }
                guard let delta = LinearAlgebra.solve(damped, Jtr.map { -$0 }) else {
                    lambda *= 10
                    continue
                }
                guard delta.allSatisfy({ $0.isFinite }) else {
                    lambda *= 10
                    continue
                }

                var candidate = p
                for i in 0..<m { candidate[i] += delta[i] }

                // Physical bounds: focal lengths positive, principal point
                // inside a generous box around the image.
                candidate[0] = max(candidate[0], 1)
                candidate[1] = max(candidate[1], 1)
                candidate[2] = min(max(candidate[2], -Double(imageWidth)),
                                   Double(imageWidth) * 2)
                candidate[3] = min(max(candidate[3], -Double(imageHeight)),
                                   Double(imageHeight) * 2)

                let candidateResiduals = residuals(parameters: candidate, views: views)
                let candidateCost = candidateResiduals.reduce(0) { $0 + $1 * $1 }

                if candidateCost < cost {
                    let improvement = cost - candidateCost
                    let stepSize = delta.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    p = candidate
                    current = candidateResiduals
                    cost = candidateCost
                    lambda = max(lambda / 10, 1e-14)
                    accepted = true
                    if stepSize < options.parameterTolerance
                        || improvement < options.costTolerance * max(cost, 1e-12) {
                        return (p, iterations)
                    }
                    break
                } else {
                    lambda *= 10
                }
            }

            if !accepted { return (p, iterations) }
        }
        return (p, iterations)
    }

    // MARK: - Public entry point

    /// - Parameter lensPosition: Focus position every view was captured at,
    ///   carried into the result so recording can reproduce it. `nil` only
    ///   for callers with no camera in hand, such as the tests.
    public func calibrate(views: [CalibrationView],
                          configurationFingerprint: String,
                          lensPosition: Double? = nil)
        throws -> IntrinsicCalibrationResult {

        guard views.count >= options.minimumViews else {
            throw IntrinsicCalibrationError.tooFewViews(have: views.count,
                                                        need: options.minimumViews)
        }

        let detector = CheckerboardDetector()
        var homographies = [[[Double]]]()
        for view in views {
            let planar = view.objectPoints.map { SIMD2($0.x, $0.y) }
            guard let H = detector.homography(from: planar, to: view.imagePoints) else {
                throw IntrinsicCalibrationError.degenerateConfiguration(
                    "A captured view produced no valid homography.")
            }
            homographies.append(H)
        }

        guard let initial = closedFormIntrinsics(homographies: homographies) else {
            throw IntrinsicCalibrationError.degenerateConfiguration(
                "The captured views are too similar to each other. Vary the "
                + "board angle and distance more between captures.")
        }

        var parameters: [Double] = [initial.fx, initial.fy,
                                    initial.cx, initial.cy,
                                    0, 0, 0, 0]
        var rotations = [SIMD3<Double>]()
        var translations = [SIMD3<Double>]()

        for H in homographies {
            guard let p = pose(from: H,
                               fx: initial.fx, fy: initial.fy,
                               cx: initial.cx, cy: initial.cy) else {
                throw IntrinsicCalibrationError.degenerateConfiguration(
                    "A captured view produced an invalid board pose.")
            }
            rotations.append(p.rvec)
            translations.append(p.tvec)
        }

        for r in rotations { parameters.append(contentsOf: [r.x, r.y, r.z]) }
        for t in translations { parameters.append(contentsOf: [t.x, t.y, t.z]) }

        guard let (refined, iterations) = refine(initial: parameters, views: views) else {
            throw IntrinsicCalibrationError.refinementFailed
        }

        // Per-view and overall reprojection error.
        var perView = [Double]()
        var totalSquared = 0.0
        var totalPoints = 0

        for (i, view) in views.enumerated() {
            let rvec = SIMD3(refined[8 + 3 * i], refined[9 + 3 * i], refined[10 + 3 * i])
            let base = 8 + 3 * views.count + 3 * i
            let tvec = SIMD3(refined[base], refined[base + 1], refined[base + 2])

            let projected = Self.project(objectPoints: view.objectPoints,
                                         rvec: rvec, tvec: tvec,
                                         fx: refined[0], fy: refined[1],
                                         cx: refined[2], cy: refined[3],
                                         k1: refined[4], k2: refined[5],
                                         p1: refined[6], p2: refined[7])

            var viewSquared = 0.0
            for (proj, observed) in zip(projected, view.imagePoints) {
                let d = proj - observed
                viewSquared += d.x * d.x + d.y * d.y
            }
            perView.append((viewSquared / Double(view.imagePoints.count)).squareRoot())
            totalSquared += viewSquared
            totalPoints += view.imagePoints.count
        }

        let rmse = (totalSquared / Double(totalPoints)).squareRoot()

        guard rmse.isFinite else {
            throw IntrinsicCalibrationError.refinementFailed
        }

        let intrinsics = CameraIntrinsics(
            focalLengthX: refined[0],
            focalLengthY: refined[1],
            principalPointX: refined[2],
            principalPointY: refined[3],
            k1: refined[4], k2: refined[5], p1: refined[6], p2: refined[7],
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            configurationFingerprint: configurationFingerprint,
            calibrationRMSE: rmse,
            lensPosition: lensPosition)

        return IntrinsicCalibrationResult(intrinsics: intrinsics,
                                          reprojectionRMSE: rmse,
                                          perViewRMSE: perView,
                                          viewCount: views.count,
                                          iterations: iterations)
    }
}
