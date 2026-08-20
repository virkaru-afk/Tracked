import Foundation
import simd

// =====================================================================
// WORLD FRAME
//
// Right-handed, anchored on the take-off board:
//
//   X  along the runway. The scratch line is X = 0 and the athlete
//      approaches from negative X, so take-off happens near zero and
//      every landing is at positive X.
//   Y  across the runway. The camera sits at negative Y, so the board
//      edge nearest the camera is Y = 0 and the far edge is Y = 1.22.
//   Z  up. Ground is Z = 0.
//
// Every distance the app reports is a difference in X. Getting this
// convention wrong does not produce an obviously broken number — it
// produces a plausible one that is silently a lateral measurement, so
// the convention is asserted here once and never re-derived.
// =====================================================================

/// Fixed geometry of a competition take-off board.
public enum WorldFrame {

    /// Board dimensions, from the IAAF/World Athletics specification.
    /// The board is 1.22 m across the runway and 0.20 m deep along it.
    public static let boardWidthAcrossRunway: Double = 1.22
    public static let boardDepthAlongRunway: Double = 0.20

    /// The four board corners, in the exact order the user is asked to tap
    /// them in SETUP.md §4:
    ///
    ///   1. Near scratch — closest to camera, pit-side edge
    ///   2. Far scratch
    ///   3. Far back
    ///   4. Near back
    ///
    /// Order is load-bearing. `CalibrationSolver` zips this array against the
    /// tapped pixels positionally, so a different order silently solves for a
    /// different camera. `CalibrationQuality.advice` indexes `boardCornerLabels`
    /// with the same offsets to name a mistapped point.
    public static let boardCorners: [SIMD3<Double>] = [
        SIMD3(0, 0, 0),                                        // near scratch
        SIMD3(0, boardWidthAcrossRunway, 0),                   // far scratch
        SIMD3(-boardDepthAlongRunway, boardWidthAcrossRunway, 0), // far back
        SIMD3(-boardDepthAlongRunway, 0, 0),                   // near back
    ]

    public static let boardCornerLabels: [String] = [
        "Near scratch corner",
        "Far scratch corner",
        "Far back corner",
        "Near back corner",
    ]

    /// X of the scratch line. Named rather than written as a literal zero
    /// because `PhaseSegmenter.segment` takes it as a parameter and a future
    /// change to the origin must not silently desynchronise the two.
    public static let scratchLineX: Double = 0

    /// Lateral centre of the runway, used as the default athlete plane before
    /// the reconstruction measures the real one.
    public static let runwayCentreY: Double = boardWidthAcrossRunway / 2
}

/// The upright reference marker that supplies the vertical scale.
///
/// A single view of a planar board cannot fix distance and focal length
/// independently — they trade off exactly. The pipe breaks that degeneracy by
/// putting a known length out of the ground plane, which is why it is not
/// optional and why its measured height must be the real one.
public struct ReferencePipe: Codable, Equatable, Sendable {

    /// Ground-to-marker-centre, in metres. Enter what you measured, not what
    /// the pipe is nominally: a 1.48 m pipe entered as 1.50 puts a 1.3% scale
    /// error into every distance the app reports.
    public var height: Double

    /// Where the pipe's base sits in the world frame. Default is 0.60 m
    /// upstream of the scratch line and 0.30 m outside the near board edge —
    /// clear of both the athlete's line and the camera's view of the board.
    public var basePosition: SIMD3<Double>

    public var topPosition: SIMD3<Double> {
        basePosition + SIMD3(0, 0, height)
    }

    public init(height: Double = 1.50,
                basePosition: SIMD3<Double> = SIMD3(-0.60, -0.30, 0)) {
        self.height = height
        self.basePosition = basePosition
    }

    private enum CodingKeys: String, CodingKey {
        case height, baseX, baseY, baseZ
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        height = try c.decode(Double.self, forKey: .height)
        basePosition = SIMD3(try c.decode(Double.self, forKey: .baseX),
                             try c.decode(Double.self, forKey: .baseY),
                             try c.decode(Double.self, forKey: .baseZ))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(height, forKey: .height)
        try c.encode(basePosition.x, forKey: .baseX)
        try c.encode(basePosition.y, forKey: .baseY)
        try c.encode(basePosition.z, forKey: .baseZ)
    }
}

// MARK: - Intrinsics

/// Lens parameters for one camera in one capture configuration.
///
/// Bound to a configuration fingerprint rather than to a device, because
/// high-frame-rate modes crop the sensor: a 1080p120 calibration applied to
/// 1080p240 footage is a silent scale error of several percent, and nothing
/// in the resulting video indicates it happened. `ConsistencyGuard` refuses
/// to analyse a recording whose fingerprint does not match its profile.
public struct CameraIntrinsics: Codable, Equatable, Sendable {

    public var focalLengthX: Double
    public var focalLengthY: Double
    public var principalPointX: Double
    public var principalPointY: Double

    /// Brown-Conrady radial terms. Two are enough for a phone lens; a third
    /// is poorly constrained by the number of views a user will realistically
    /// capture and tends to absorb noise rather than distortion.
    public var k1: Double
    public var k2: Double

    /// Tangential terms, from sensor/lens decentring. Small on phones but not
    /// zero, and cheap to carry.
    public var p1: Double
    public var p2: Double

    public var imageWidth: Int
    public var imageHeight: Int

    /// Device, resolution and frame rate this calibration is valid for.
    public var configurationFingerprint: String

    /// RMS reprojection error from the calibration that produced these, in
    /// pixels. Kept so the UI can state the quality without re-deriving it.
    public var calibrationRMSE: Double

    /// Lens focus position these intrinsics were measured at, `0` near to
    /// `1` far. Re-applied before recording so the footage is shot at the
    /// focal length that was actually calibrated.
    ///
    /// The mode fingerprint cannot cover this. Two calibrations of the same
    /// device in the same mode at different focus distances produce identical
    /// fingerprints and different focal lengths, so without this the guard
    /// waves through a profile that silently rescales every distance.
    ///
    /// Optional because profiles calibrated before focus position was
    /// recorded decode as `nil`. Those are not necessarily wrong, merely
    /// unverifiable — `ConsistencyGuard` says exactly that rather than
    /// assuming either way.
    public var lensPosition: Double?

    public init(focalLengthX: Double,
                focalLengthY: Double,
                principalPointX: Double,
                principalPointY: Double,
                k1: Double = 0,
                k2: Double = 0,
                p1: Double = 0,
                p2: Double = 0,
                imageWidth: Int,
                imageHeight: Int,
                configurationFingerprint: String,
                calibrationRMSE: Double = 0,
                lensPosition: Double? = nil) {
        self.focalLengthX = focalLengthX
        self.focalLengthY = focalLengthY
        self.principalPointX = principalPointX
        self.principalPointY = principalPointY
        self.k1 = k1
        self.k2 = k2
        self.p1 = p1
        self.p2 = p2
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.configurationFingerprint = configurationFingerprint
        self.calibrationRMSE = calibrationRMSE
        self.lensPosition = lensPosition
    }

    /// Horizontal field of view in degrees, for display only.
    public var horizontalFieldOfView: Double {
        2 * atan(Double(imageWidth) / (2 * focalLengthX)) * 180 / .pi
    }

    // MARK: Distortion

    /// Where an ideal pinhole pixel actually lands once the lens has had its
    /// way with it. Pixel domain in, pixel domain out.
    public func distort(_ ideal: SIMD2<Double>) -> SIMD2<Double> {
        let x = (ideal.x - principalPointX) / focalLengthX
        let y = (ideal.y - principalPointY) / focalLengthY
        let d = distortNormalised(SIMD2(x, y))
        return SIMD2(d.x * focalLengthX + principalPointX,
                     d.y * focalLengthY + principalPointY)
    }

    /// Inverse of `distort`. Observed pixel in, ideal pinhole pixel out.
    ///
    /// The Brown-Conrady model has no closed-form inverse, so this iterates.
    /// Five passes converge to well under a hundredth of a pixel over the
    /// distortion range a phone lens produces — far tighter than the ~2 px tap
    /// noise that dominates calibration error, so the iteration count is not
    /// worth making configurable.
    public func undistort(_ observed: SIMD2<Double>) -> SIMD2<Double> {
        let target = SIMD2((observed.x - principalPointX) / focalLengthX,
                           (observed.y - principalPointY) / focalLengthY)
        var estimate = target
        for _ in 0..<5 {
            let d = distortNormalised(estimate)
            estimate += target - d
        }
        return SIMD2(estimate.x * focalLengthX + principalPointX,
                     estimate.y * focalLengthY + principalPointY)
    }

    private func distortNormalised(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let r2 = p.x * p.x + p.y * p.y
        let radial = 1 + k1 * r2 + k2 * r2 * r2
        let tangentialX = 2 * p1 * p.x * p.y + p2 * (r2 + 2 * p.x * p.x)
        let tangentialY = p1 * (r2 + 2 * p.y * p.y) + 2 * p2 * p.x * p.y
        return SIMD2(p.x * radial + tangentialX,
                     p.y * radial + tangentialY)
    }
}

// MARK: - Pose

/// Where the camera is and which way it points.
///
/// Four parameters, not six. The tripod constrains roll to zero for practical
/// purposes, and the camera's lateral offset along the runway is absorbed into
/// yaw at the distances involved. Solving four against thirteen residuals is
/// well conditioned; solving six is not, at the tap precision a user can
/// actually achieve.
public struct CameraPose: Codable, Equatable, Sendable {

    /// Perpendicular distance from the board plane, in metres. Always
    /// positive; the camera is at negative Y.
    public var distance: Double

    /// Lens height above the ground, in metres.
    public var height: Double

    /// Rotation about the world Z axis, in radians. Zero means the optical
    /// axis is exactly perpendicular to the runway.
    public var yaw: Double

    /// Rotation about the camera's own X axis, in radians. Positive tilts the
    /// camera down.
    public var pitch: Double

    public init(distance: Double, height: Double, yaw: Double = 0, pitch: Double = 0) {
        self.distance = distance
        self.height = height
        self.yaw = yaw
        self.pitch = pitch
    }

    /// Camera centre in world coordinates.
    ///
    /// Placed level with the scratch line along the runway, which is where
    /// SETUP.md instructs the tripod to go. Residual offset along X is what
    /// yaw absorbs.
    public var position: SIMD3<Double> {
        SIMD3(0, -distance, height)
    }

    /// World-to-camera rotation.
    ///
    /// Composed in a fixed order — yaw about world Z, then into the camera's
    /// base orientation, then pitch about the camera's own X. The order is
    /// part of the parameterisation the solver differentiates through, so it
    /// cannot be changed without re-validating the solve.
    public var rotation: simd_double3x3 {
        // Base: optical axis along world +Y, image X along world +X, image Y
        // along world -Z. Columns are the images of the world basis vectors.
        let base = simd_double3x3(
            SIMD3(1, 0, 0),   // world X -> camera X
            SIMD3(0, 0, 1),   // world Y -> camera Z
            SIMD3(0, -1, 0))  // world Z -> camera -Y

        let cy = cos(-yaw), sy = sin(-yaw)
        let yawRotation = simd_double3x3(
            SIMD3(cy, sy, 0),
            SIMD3(-sy, cy, 0),
            SIMD3(0, 0, 1))

        let cp = cos(pitch), sp = sin(pitch)
        let pitchRotation = simd_double3x3(
            SIMD3(1, 0, 0),
            SIMD3(0, cp, sp),
            SIMD3(0, -sp, cp))

        return pitchRotation * base * yawRotation
    }

    public var yawDegrees: Double { yaw * 180 / .pi }
    public var pitchDegrees: Double { pitch * 180 / .pi }
}

// MARK: - Camera model

/// Intrinsics and pose together: the full world-to-pixel map.
public struct CameraModel: Sendable {

    public let intrinsics: CameraIntrinsics
    public let pose: CameraPose

    private let rotation: simd_double3x3
    private let centre: SIMD3<Double>

    public init(intrinsics: CameraIntrinsics, pose: CameraPose) {
        self.intrinsics = intrinsics
        self.pose = pose
        self.rotation = pose.rotation
        self.centre = pose.position
    }

    /// World point to camera coordinates. +Z is forward along the optical axis.
    public func cameraCoordinates(_ world: SIMD3<Double>) -> SIMD3<Double> {
        rotation * (world - centre)
    }

    /// World point to pixel, with distortion applied.
    ///
    /// Returns nil when the point is behind the camera. The solver depends on
    /// this being nil rather than a wrapped-around pixel: a point behind the
    /// lens projected naively lands somewhere plausible on the far side of the
    /// frame and would be scored as a small residual.
    public func project(_ world: SIMD3<Double>) -> SIMD2<Double>? {
        let c = cameraCoordinates(world)
        guard c.z > 1e-6 else { return nil }
        let ideal = SIMD2(intrinsics.focalLengthX * (c.x / c.z) + intrinsics.principalPointX,
                          intrinsics.focalLengthY * (c.y / c.z) + intrinsics.principalPointY)
        return intrinsics.distort(ideal)
    }

    /// The ray through a pixel, as an origin and a unit direction in world
    /// coordinates.
    public func ray(through pixel: SIMD2<Double>) -> (origin: SIMD3<Double>,
                                                       direction: SIMD3<Double>) {
        let ideal = intrinsics.undistort(pixel)
        let cameraDirection = SIMD3(
            (ideal.x - intrinsics.principalPointX) / intrinsics.focalLengthX,
            (ideal.y - intrinsics.principalPointY) / intrinsics.focalLengthY,
            1.0)
        let worldDirection = rotation.transpose * cameraDirection
        return (centre, simd_normalize(worldDirection))
    }

    /// Where a pixel's ray meets a plane of constant Y.
    ///
    /// This is the whole of single-camera 3D reconstruction. The athlete is
    /// assumed to move in one lateral plane; given that plane, every pixel has
    /// exactly one world point. The assumption is what limits the method — see
    /// `Reconstructor` — but within it the geometry is exact.
    public func intersectPlaneY(_ planeY: Double,
                                pixel: SIMD2<Double>) -> SIMD3<Double>? {
        let (origin, direction) = ray(through: pixel)
        guard abs(direction.y) > 1e-9 else { return nil }
        let t = (planeY - origin.y) / direction.y
        guard t > 0 else { return nil }
        return origin + direction * t
    }

    /// Where a pixel's ray meets the ground plane, Z = 0.
    public func intersectGround(pixel: SIMD2<Double>) -> SIMD3<Double>? {
        let (origin, direction) = ray(through: pixel)
        guard abs(direction.z) > 1e-9 else { return nil }
        let t = -origin.z / direction.z
        guard t > 0 else { return nil }
        return origin + direction * t
    }

    /// Metres per pixel at a given lateral plane, for the vertical axis.
    ///
    /// Used to translate pose-estimator pixel noise into a physical error bar
    /// so the UI can state uncertainty in millimetres rather than pixels.
    public func metresPerPixel(atPlaneY planeY: Double) -> Double {
        let depth = abs(planeY - centre.y)
        return depth / intrinsics.focalLengthY
    }
}
