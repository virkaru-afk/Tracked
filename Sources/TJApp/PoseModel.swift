import Foundation
import simd

/// The 33 body landmarks MediaPipe Pose emits, with their wire indices.
///
/// Raw values match MediaPipe's ordering exactly so a landmark array can be
/// indexed by `rawValue` without a lookup table. Do not reorder.
public enum PoseLandmark: Int, CaseIterable, Codable, Sendable, Hashable {
    case nose = 0
    case leftEyeInner = 1, leftEye = 2, leftEyeOuter = 3
    case rightEyeInner = 4, rightEye = 5, rightEyeOuter = 6
    case leftEar = 7, rightEar = 8
    case mouthLeft = 9, mouthRight = 10
    case leftShoulder = 11, rightShoulder = 12
    case leftElbow = 13, rightElbow = 14
    case leftWrist = 15, rightWrist = 16
    case leftPinky = 17, rightPinky = 18
    case leftIndex = 19, rightIndex = 20
    case leftThumb = 21, rightThumb = 22
    case leftHip = 23, rightHip = 24
    case leftKnee = 25, rightKnee = 26
    case leftAnkle = 27, rightAnkle = 28
    case leftHeel = 29, rightHeel = 30
    case leftFootIndex = 31, rightFootIndex = 32

    public var isLeft: Bool {
        switch self {
        case .leftEyeInner, .leftEye, .leftEyeOuter, .leftEar, .mouthLeft,
             .leftShoulder, .leftElbow, .leftWrist, .leftPinky, .leftIndex,
             .leftThumb, .leftHip, .leftKnee, .leftAnkle, .leftHeel,
             .leftFootIndex:
            return true
        default:
            return false
        }
    }

    /// The landmarks this app actually measures from.
    ///
    /// Face and hand points are tracked by the model but never used: they add
    /// nothing to a distance or a contact time, and including them in the
    /// confidence average would let a well-tracked face mask badly-tracked
    /// feet — which is exactly the failure that matters.
    public static let analysed: [PoseLandmark] = [
        .leftShoulder, .rightShoulder,
        .leftHip, .rightHip,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
        .leftHeel, .rightHeel,
        .leftFootIndex, .rightFootIndex,
    ]

    /// Foot landmarks for one side, in the order the event detector prefers
    /// them: whichever is lowest wins, with the ankle as a fallback.
    public static func footLandmarks(side: GroundEvent.Side)
        -> (heel: PoseLandmark, toe: PoseLandmark, ankle: PoseLandmark) {
        side == .left
            ? (.leftHeel, .leftFootIndex, .leftAnkle)
            : (.rightHeel, .rightFootIndex, .rightAnkle)
    }

    public static func hip(side: GroundEvent.Side) -> PoseLandmark {
        side == .left ? .leftHip : .rightHip
    }

    public static func knee(side: GroundEvent.Side) -> PoseLandmark {
        side == .left ? .leftKnee : .rightKnee
    }

    public static func shoulder(side: GroundEvent.Side) -> PoseLandmark {
        side == .left ? .leftShoulder : .rightShoulder
    }

    /// Skeleton connections for the overlay, as landmark pairs.
    public static let connections: [(PoseLandmark, PoseLandmark)] = [
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel), (.leftHeel, .leftFootIndex),
        (.leftAnkle, .leftFootIndex),
        (.rightAnkle, .rightHeel), (.rightHeel, .rightFootIndex),
        (.rightAnkle, .rightFootIndex),
    ]

    public var displayName: String {
        switch self {
        case .leftShoulder: return "Left shoulder"
        case .rightShoulder: return "Right shoulder"
        case .leftHip: return "Left hip"
        case .rightHip: return "Right hip"
        case .leftKnee: return "Left knee"
        case .rightKnee: return "Right knee"
        case .leftAnkle: return "Left ankle"
        case .rightAnkle: return "Right ankle"
        case .leftHeel: return "Left heel"
        case .rightHeel: return "Right heel"
        case .leftFootIndex: return "Left toe"
        case .rightFootIndex: return "Right toe"
        default: return "\(self)"
        }
    }
}

// MARK: - 2D

/// One landmark as the pose estimator saw it, in pixels.
public struct Keypoint2D: Codable, Sendable, Equatable {
    /// Pixel position in the full-resolution frame.
    public var position: SIMD2<Double>
    /// Model confidence, 0...1.
    public var confidence: Double
    /// MediaPipe's own visibility score. Distinct from confidence: a landmark
    /// can be located precisely and still be occluded, and an occluded foot
    /// is exactly the case where a contact gets placed on a guess.
    public var visibility: Double

    public init(position: SIMD2<Double>, confidence: Double, visibility: Double = 1) {
        self.position = position
        self.confidence = confidence
        self.visibility = visibility
    }
}

/// One video frame's worth of 2D pose, before reconstruction.
public struct PoseFrame: Codable, Sendable {

    public var timestamp: Double
    public var frameIndex: Int
    public var keypoints: [PoseLandmark: Keypoint2D]

    public init(timestamp: Double,
                frameIndex: Int,
                keypoints: [PoseLandmark: Keypoint2D]) {
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.keypoints = keypoints
    }

    public subscript(landmark: PoseLandmark) -> Keypoint2D? {
        keypoints[landmark]
    }

    /// Mean confidence over the landmarks this app measures from.
    ///
    /// `ConsistencyGuard` gates on this. Averaging over analysed landmarks
    /// only is the point: the model reports high confidence on a face that is
    /// large and well lit while the feet — small, fast, and often motion
    /// blurred — are the landmarks every measurement actually depends on.
    public var analysisConfidence: Double {
        let values = PoseLandmark.analysed.compactMap { keypoints[$0]?.confidence }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// True when both feet are tracked well enough to time a contact from.
    public var hasUsableFeet: Bool {
        let feet: [PoseLandmark] = [.leftHeel, .leftFootIndex,
                                    .rightHeel, .rightFootIndex]
        return feet.compactMap { keypoints[$0] }.filter { $0.confidence > 0.5 }.count >= 2
    }

    // Dictionaries keyed by a non-String enum need explicit coding.
    private enum CodingKeys: String, CodingKey {
        case timestamp, frameIndex, landmarks, points
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        frameIndex = try c.decode(Int.self, forKey: .frameIndex)
        let indices = try c.decode([Int].self, forKey: .landmarks)
        let points = try c.decode([Keypoint2D].self, forKey: .points)
        var result = [PoseLandmark: Keypoint2D]()
        for (index, point) in zip(indices, points) {
            if let landmark = PoseLandmark(rawValue: index) { result[landmark] = point }
        }
        keypoints = result
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(frameIndex, forKey: .frameIndex)
        let ordered = keypoints.sorted { $0.key.rawValue < $1.key.rawValue }
        try c.encode(ordered.map(\.key.rawValue), forKey: .landmarks)
        try c.encode(ordered.map(\.value), forKey: .points)
    }
}

// MARK: - 3D

/// How a 3D point was recovered, which determines how far it can be trusted.
public enum ReconstructionMethod: String, Codable, Sendable {
    /// Ray intersected with the athlete's measured lateral plane. The normal
    /// case and the most accurate.
    case sagittalPlane
    /// Ray intersected with the ground plane, Z = 0. Used for a foot known to
    /// be in contact, where the ground is a harder constraint than the
    /// assumed athlete plane.
    case groundPlane
    /// Position carried or interpolated across a tracking gap. Real
    /// measurement should avoid depending on these; the event detector
    /// penalises confidence when a contact boundary lands on one.
    case interpolated
}

/// One landmark in world coordinates.
public struct Keypoint3D: Sendable, Equatable {
    public var position: SIMD3<Double>
    public var confidence: Double
    public var method: ReconstructionMethod

    public init(position: SIMD3<Double>,
                confidence: Double,
                method: ReconstructionMethod = .sagittalPlane) {
        self.position = position
        self.confidence = confidence
        self.method = method
    }
}

/// One frame of reconstructed 3D pose on the canonical analysis timebase.
///
/// This is the type every measurement is taken from. By the time a frame
/// exists here it has been resampled onto this session's canonical grid (see
/// `ProcessingTimebase`), so `frameIndex` refers to the analysis grid rather
/// than to a position in the source video — the two differ whenever the
/// camera delivered something other than exactly its nominal rate, which is
/// always.
public struct ReconstructedFrame: Sendable {

    public var timestamp: Double
    public var frameIndex: Int
    public var keypoints: [PoseLandmark: Keypoint3D]

    /// True when this frame's pose was invented to bridge a tracking gap
    /// rather than measured. `EventDetector` reduces contact confidence in
    /// proportion to how many interpolated frames a contact spans.
    public var isInterpolated: Bool

    /// The lateral plane this frame was reconstructed against, in metres.
    /// Retained so a re-analysis can reproduce the geometry exactly.
    public var athletePlaneY: Double

    public init(timestamp: Double,
                frameIndex: Int,
                keypoints: [PoseLandmark: Keypoint3D],
                isInterpolated: Bool = false,
                athletePlaneY: Double = WorldFrame.runwayCentreY) {
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.keypoints = keypoints
        self.isInterpolated = isInterpolated
        self.athletePlaneY = athletePlaneY
    }

    public subscript(landmark: PoseLandmark) -> Keypoint3D? {
        keypoints[landmark]
    }

    /// Midpoint of the hips — the closest thing to a whole-body position that
    /// does not swing with the limbs.
    public var hipCentre: SIMD3<Double>? {
        guard let left = keypoints[.leftHip], let right = keypoints[.rightHip] else {
            return keypoints[.leftHip]?.position ?? keypoints[.rightHip]?.position
        }
        return (left.position + right.position) / 2
    }

    public var shoulderCentre: SIMD3<Double>? {
        guard let left = keypoints[.leftShoulder],
              let right = keypoints[.rightShoulder] else {
            return keypoints[.leftShoulder]?.position
                ?? keypoints[.rightShoulder]?.position
        }
        return (left.position + right.position) / 2
    }

    public var meanConfidence: Double {
        let values = PoseLandmark.analysed.compactMap { keypoints[$0]?.confidence }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Angles

/// Joint angle helpers.
///
/// Every angle here is measured in the sagittal plane, which is the only
/// plane a single camera can resolve. Out-of-plane motion — arm swing, trunk
/// drift — leaks in as roughly 10% error, which is why every angle metric
/// carries the `indicative` tier rather than a millimetre figure.
public enum JointAngles {

    /// Interior angle at `vertex`, in degrees, between the two limb segments.
    public static func angle(at vertex: SIMD3<Double>,
                             from a: SIMD3<Double>,
                             to b: SIMD3<Double>) -> Double? {
        let u = a - vertex
        let v = b - vertex
        let lengths = simd_length(u) * simd_length(v)
        guard lengths > 1e-9 else { return nil }
        let cosine = min(max(simd_dot(u, v) / lengths, -1), 1)
        return acos(cosine) * 180 / .pi
    }

    /// Knee angle: hip-knee-ankle. 180° is a fully extended leg.
    public static func knee(_ frame: ReconstructedFrame,
                            side: GroundEvent.Side) -> Double? {
        guard let hip = frame[PoseLandmark.hip(side: side)]?.position,
              let knee = frame[PoseLandmark.knee(side: side)]?.position,
              let ankle = frame[side == .left ? .leftAnkle : .rightAnkle]?.position
        else { return nil }
        return angle(at: knee, from: hip, to: ankle)
    }

    /// Trunk lean from vertical, in degrees, in the sagittal plane.
    ///
    /// Positive is forward lean, in the direction of travel. Sign matters
    /// here: backward lean at touchdown accompanies a braking contact, and a
    /// magnitude-only value would hide the distinction.
    public static func trunkLean(_ frame: ReconstructedFrame) -> Double? {
        guard let hips = frame.hipCentre,
              let shoulders = frame.shoulderCentre else { return nil }
        let trunk = shoulders - hips
        // Sagittal plane is X (along runway) and Z (up).
        guard abs(trunk.z) > 1e-9 else { return nil }
        return atan2(trunk.x, trunk.z) * 180 / .pi
    }
}
