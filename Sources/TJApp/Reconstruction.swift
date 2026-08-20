import Foundation
import simd

/// Turns 2D pose observations into 3D world positions.
///
/// A single camera cannot recover depth. What makes this tractable is that a
/// triple jumper runs down a runway: their motion is confined, to a good
/// approximation, to one lateral plane. Given that plane, every pixel maps to
/// exactly one world point and the geometry is exact.
///
/// The assumption is also the method's limit. Motion out of that plane — arm
/// swing, trunk drift, a foot planted slightly wide — is unrecoverable and
/// leaks in as error, which is why joint angles carry the `indicative` tier
/// while distances along the runway, which lie *in* the plane, do not.
///
/// The plane is measured from the footage rather than assumed. Assuming the
/// runway centreline costs real accuracy: an athlete running 15 cm off centre
/// at a 4 m camera distance produces a ~4% scale error on every horizontal
/// measurement, which is 20 cm on a 5 m hop.
public struct Reconstructor {

    public let model: CameraModel

    public struct Options: Sendable {
        /// Landmarks below this confidence are treated as missing rather than
        /// trusted. The pose model reports a position for an occluded joint
        /// with low confidence rather than reporting nothing, and taking
        /// those at face value puts invented geometry into the measurement.
        public var minimumLandmarkConfidence: Double = 0.35

        /// Longest tracking gap that will be interpolated across, in seconds.
        /// Beyond this the position is held rather than interpolated —
        /// inventing a trajectory across a long gap would manufacture a
        /// motion the athlete never made.
        public var maximumInterpolationSeconds: Double = 0.10

        /// Percentile of foot ground-intersections used to fix the athlete
        /// plane. See `measureAthletePlane`.
        public var planePercentile: Double = 0.10

        /// Sanity bounds on the recovered plane, in metres from the board's
        /// near edge. A plane outside this is a solve failure, not an
        /// athlete running unusually wide.
        public var planeBounds: ClosedRange<Double> = -0.5...2.5

        public init() {}
    }

    public var options = Options()

    public init(model: CameraModel, options: Options = Options()) {
        self.model = model
        self.options = options
    }

    // MARK: - Plane measurement

    /// Estimate the lateral plane the athlete moves in.
    ///
    /// Every foot pixel's ray is intersected with the ground, Z = 0. When the
    /// foot is genuinely on the ground that intersection is the true foot
    /// position, so its Y is the athlete's plane. When the foot is in the air
    /// the ray passes over the athlete and strikes the ground somewhere
    /// beyond them — always *further* from the camera, so always a larger Y.
    ///
    /// The true plane is therefore near the bottom of the distribution, and a
    /// low percentile finds it without needing to know which frames are
    /// contacts. That matters: contact detection needs 3D positions, which
    /// need the plane, so anything requiring contacts first would be circular.
    public func measureAthletePlane(poseFrames: [PoseFrame]) -> (plane: Double,
                                                                 confidence: Double) {
        var groundYs = [Double]()

        for frame in poseFrames {
            for side in [GroundEvent.Side.left, .right] {
                let landmarks = PoseLandmark.footLandmarks(side: side)
                let candidates = [landmarks.heel, landmarks.toe]
                    .compactMap { frame[$0] }
                    .filter { $0.confidence >= options.minimumLandmarkConfidence }

                // Lowest foot point in the image is the one nearest the
                // ground; in image coordinates that is the largest Y.
                guard let lowest = candidates.max(by: { $0.position.y < $1.position.y })
                else { continue }

                if let world = model.intersectGround(pixel: lowest.position),
                   options.planeBounds.contains(world.y) {
                    groundYs.append(world.y)
                }
            }
        }

        guard groundYs.count >= 20 else {
            // Not enough usable feet to measure anything. Fall back to the
            // runway centreline and say so through the confidence, rather
            // than silently proceeding as though it had been measured.
            return (WorldFrame.runwayCentreY, 0)
        }

        groundYs.sort()
        let index = min(max(Int(Double(groundYs.count) * options.planePercentile), 0),
                        groundYs.count - 1)
        let plane = groundYs[index]

        // Spread of the lowest fifth of the distribution. A tight cluster
        // means many frames agree on where the ground contact was; a wide one
        // means the feet were poorly tracked and the plane is a guess.
        let lowerFifth = groundYs.prefix(max(groundYs.count / 5, 2))
        let mean = lowerFifth.reduce(0, +) / Double(lowerFifth.count)
        let variance = lowerFifth.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(lowerFifth.count)
        let spread = variance.squareRoot()

        // 30 mm of spread is good; 150 mm means the plane is barely resolved.
        let confidence = max(0, min(1, 1 - (spread - 0.03) / 0.12))
        return (plane, confidence)
    }

    // MARK: - Reconstruction

    public struct Output: Sendable {
        public var frames: [ReconstructedFrame]
        public var athletePlaneY: Double
        public var planeConfidence: Double
        public var interpolatedFrameCount: Int
        public var warnings: [String]
    }

    /// Full pipeline: resample onto the canonical grid, measure the plane,
    /// then project every landmark onto it.
    public func reconstruct(poseFrames: [PoseFrame]) -> Output {
        var warnings = [String]()

        guard poseFrames.count >= 2 else {
            return Output(frames: [], athletePlaneY: WorldFrame.runwayCentreY,
                          planeConfidence: 0, interpolatedFrameCount: 0,
                          warnings: ["Not enough pose data to reconstruct."])
        }

        let (plane, planeConfidence) = measureAthletePlane(poseFrames: poseFrames)
        if planeConfidence < 0.4 {
            warnings.append(
                "The athlete's line across the runway could not be measured "
                + "confidently, so distances may carry a scale error. This usually "
                + "means the feet were poorly tracked — check lighting and that "
                + "nothing crossed between the camera and the runway.")
        }

        let resampled = resampleOntoGrid(poseFrames: poseFrames)

        var frames = [ReconstructedFrame]()
        frames.reserveCapacity(resampled.count)
        var interpolatedCount = 0

        for sample in resampled {
            var keypoints = [PoseLandmark: Keypoint3D]()

            for (landmark, point) in sample.keypoints {
                guard point.confidence >= options.minimumLandmarkConfidence else {
                    continue
                }
                guard let world = model.intersectPlaneY(plane, pixel: point.position)
                else { continue }

                keypoints[landmark] = Keypoint3D(
                    position: world,
                    confidence: point.confidence,
                    method: sample.isInterpolated ? .interpolated : .sagittalPlane)
            }

            if sample.isInterpolated { interpolatedCount += 1 }

            frames.append(ReconstructedFrame(timestamp: sample.timestamp,
                                             frameIndex: sample.frameIndex,
                                             keypoints: keypoints,
                                             isInterpolated: sample.isInterpolated,
                                             athletePlaneY: plane))
        }

        let interpolatedFraction = Double(interpolatedCount) / Double(max(frames.count, 1))
        if interpolatedFraction > 0.2 {
            warnings.append(
                "\(Int(interpolatedFraction * 100))% of frames had to be filled in "
                + "because body tracking dropped out. Contact times spanning those "
                + "frames are less reliable.")
        }

        return Output(frames: frames,
                      athletePlaneY: plane,
                      planeConfidence: planeConfidence,
                      interpolatedFrameCount: interpolatedCount,
                      warnings: warnings)
    }

    // MARK: - Resampling

    private struct GridSample {
        var timestamp: Double
        var frameIndex: Int
        var keypoints: [PoseLandmark: Keypoint2D]
        var isInterpolated: Bool
    }

    /// Put the 2D observations on this session's canonical analysis grid —
    /// see `ProcessingTimebase`, which by the time this runs has already
    /// been configured for the recording's own measured frame rate.
    ///
    /// Resampling happens in pixel space, before reconstruction, rather than
    /// after. Both orders are geometrically defensible, but interpolating
    /// pixels keeps the operation linear in the domain the noise actually
    /// lives in — pose-estimator jitter is a pixel-space quantity, and
    /// interpolating world positions would let the perspective divide
    /// redistribute that noise unevenly along the runway.
    private func resampleOntoGrid(poseFrames: [PoseFrame]) -> [GridSample] {
        let sorted = poseFrames.sorted { $0.timestamp < $1.timestamp }
        guard let start = sorted.first?.timestamp,
              let end = sorted.last?.timestamp else { return [] }

        let grid = Resampler.grid(from: start, to: end)
        let sourceTimes = sorted.map(\.timestamp)

        // Which source frames actually observed each landmark. A landmark
        // missing from a frame is a gap to be bridged, not a zero.
        var samples = grid.enumerated().map { index, time in
            GridSample(timestamp: time,
                       frameIndex: index,
                       keypoints: [:],
                       isInterpolated: false)
        }

        for landmark in PoseLandmark.allCases {
            let observed = sorted.enumerated().compactMap { index, frame -> (Double, Keypoint2D)? in
                guard let point = frame[landmark],
                      point.confidence >= options.minimumLandmarkConfidence else {
                    return nil
                }
                return (sourceTimes[index], point)
            }
            guard observed.count >= 2 else { continue }

            let times = observed.map(\.0)
            let xs = Resampler.resample(timestamps: times,
                                        values: observed.map(\.1.position.x),
                                        toGrid: grid)
            let ys = Resampler.resample(timestamps: times,
                                        values: observed.map(\.1.position.y),
                                        toGrid: grid)
            let confidences = Resampler.resample(timestamps: times,
                                                 values: observed.map(\.1.confidence),
                                                 toGrid: grid)

            for (index, time) in grid.enumerated() {
                // A grid point sitting in a long gap between observations is
                // interpolated across nothing real. Mark it so the event
                // detector can discount contacts that depend on it.
                let gap = nearestGap(time: time, in: times)
                let bridged = gap > options.maximumInterpolationSeconds
                if bridged {
                    samples[index].isInterpolated = true
                }
                samples[index].keypoints[landmark] = Keypoint2D(
                    position: SIMD2(xs[index], ys[index]),
                    confidence: bridged ? confidences[index] * 0.5 : confidences[index])
            }
        }

        return samples
    }

    /// Distance from `time` to the nearest real observation.
    private func nearestGap(time: Double, in times: [Double]) -> Double {
        guard !times.isEmpty else { return .infinity }
        var low = 0, high = times.count - 1
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time { low = mid + 1 } else { high = mid }
        }
        var best = abs(times[low] - time)
        if low > 0 { best = min(best, abs(times[low - 1] - time)) }
        return best
    }
}
