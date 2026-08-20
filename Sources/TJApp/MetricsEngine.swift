import Foundation
import simd

/// Computes the measured quantities from a segmented trial.
///
/// Every key this emits must exist in `MetricCatalog` and in
/// `TrendAnalyser.meaningfulChangeThresholds`. A metric with no catalogue
/// entry is dropped before display, and one with no threshold has no
/// validated noise floor, so the comparison view cannot say whether a change
/// in it is real. Adding a metric means adding it in all three places.
///
/// All values are stored in SI — metres, seconds, metres per second, degrees.
/// The feet-and-inches conversion happens in the view layer and nowhere else.
public struct MetricsEngine {

    public struct Options: Sendable {
        /// Fraction trimmed from each end of a contact before taking the
        /// plant position. The boundary frames sit in the transition where
        /// the foot is still travelling several metres per second, so one
        /// frame of jitter moves them centimetres — including them inflated
        /// phase-distance variance from 5 mm to 228 mm in validation.
        public var contactTrimFraction: Double = 0.2

        /// Window before take-off used to measure approach velocity, in
        /// seconds. Long enough to average out stride oscillation, short
        /// enough not to reach back into a different part of the run-up.
        public var approachWindowSeconds: Double = 0.20

        public init() {}
    }

    public var options = Options()

    public init(options: Options = Options()) {
        self.options = options
    }

    public struct Output: Sendable {
        public var values: [String: Double]
        public var confidences: [String: Double]
        public var warnings: [String]
    }

    // MARK: - Entry point

    public func measure(frames: [ReconstructedFrame],
                        segmentation: PhaseSegmentation) -> Output {

        var values = [String: Double]()
        var confidences = [String: Double]()
        var warnings = segmentation.warnings

        guard !frames.isEmpty, !segmentation.phases.isEmpty else {
            return Output(values: [:], confidences: [:],
                          warnings: warnings + ["No phases were segmented, so nothing "
                                                + "could be measured."])
        }

        let index = FrameIndex(frames: frames)

        // Phase lookup. `hopContact` is the take-off on the board;
        // `stepContact` is where the hop lands; `jumpContact` is where the
        // step lands. The names describe the phase being entered, not the one
        // being left, which is worth stating because it inverts the obvious
        // reading.
        let takeoff = segmentation.phases.first { $0.phase == .hopContact }
        let hopLanding = segmentation.phases.first { $0.phase == .stepContact }
        let stepLanding = segmentation.phases.first { $0.phase == .jumpContact }
        let hopFlight = segmentation.phases.first { $0.phase == .hopFlight }
        let stepFlight = segmentation.phases.first { $0.phase == .stepFlight }

        // --- Phase distances -------------------------------------------

        let takeoffPlant = takeoff.flatMap { plantPosition(phase: $0, index: index) }
        let hopPlant = hopLanding.flatMap { plantPosition(phase: $0, index: index) }
        let stepPlant = stepLanding.flatMap { plantPosition(phase: $0, index: index) }

        var hopDistance: Double?
        var stepDistance: Double?

        if let takeoffPlant, let hopPlant {
            hopDistance = hopPlant.x - takeoffPlant.x
            values["Hop distance"] = hopDistance
            confidences["Hop distance"] = min(takeoff?.confidence ?? 0,
                                              hopLanding?.confidence ?? 0)
        }
        if let hopPlant, let stepPlant {
            stepDistance = stepPlant.x - hopPlant.x
            values["Step distance"] = stepDistance
            confidences["Step distance"] = min(hopLanding?.confidence ?? 0,
                                               stepLanding?.confidence ?? 0)
        }

        // Shares are of hop plus step, never of a total. The jump phase lands
        // in the pit where the foot is occluded and the landing is a slide
        // rather than a plant, so there is no stationary contact to measure
        // from and no jump distance to include.
        if let hopDistance, let stepDistance {
            let measured = hopDistance + stepDistance
            if measured > 0.1 {
                values["Hop share of measured phases"] = hopDistance / measured * 100
                values["Step share of measured phases"] = stepDistance / measured * 100
                let shareConfidence = min(confidences["Hop distance"] ?? 0,
                                          confidences["Step distance"] ?? 0)
                confidences["Hop share of measured phases"] = shareConfidence
                confidences["Step share of measured phases"] = shareConfidence
            }
        }

        // --- Board accuracy ---------------------------------------------

        if let takeoff, let side = takeoff.side {
            let toeLandmark: PoseLandmark = side == .left ? .leftFootIndex : .rightFootIndex
            if let plant = plantPosition(phase: takeoff, index: index,
                                         landmark: toeLandmark) {
                // Positive means the toe stopped short of the line, which is
                // legal. Negative means it crossed — a foul.
                values["Toe distance behind scratch line"] =
                    WorldFrame.scratchLineX - plant.x
                confidences["Toe distance behind scratch line"] = takeoff.confidence
            }
        }

        // --- Touchdown relative to the hips ------------------------------

        // Measured at the landings, not at the board take-off. At take-off
        // the foot is deliberately ahead of the hips as part of the jump; at
        // a landing it is a braking fault, and averaging the two would blur a
        // technique signal into an artefact of the event.
        let landingContacts = [hopLanding, stepLanding].compactMap { $0 }
        var touchdownOffsets = [Double]()
        for phase in landingContacts {
            guard let side = phase.side,
                  let frame = index.frame(at: phase.startFrame),
                  let hips = frame.hipCentre else { continue }
            let landmarks = PoseLandmark.footLandmarks(side: side)
            guard let foot = frame[landmarks.heel]?.position
                    ?? frame[landmarks.toe]?.position else { continue }
            touchdownOffsets.append(foot.x - hips.x)
        }
        if !touchdownOffsets.isEmpty {
            values["Touchdown distance ahead of hips"] =
                touchdownOffsets.reduce(0, +) / Double(touchdownOffsets.count)
            confidences["Touchdown distance ahead of hips"] =
                landingContacts.map(\.confidence).min() ?? 0
        }

        // --- Timing -------------------------------------------------------

        let contactPhases = [takeoff, hopLanding, stepLanding].compactMap { $0 }
        if !contactPhases.isEmpty {
            values["Contact time"] = contactPhases.map(\.duration).reduce(0, +)
                / Double(contactPhases.count)
            confidences["Contact time"] = contactPhases.map(\.confidence).min() ?? 0
        }

        // Jump flight is excluded: it ends where the clip ends or where the
        // athlete disappears into the pit, not at a detected landing, so its
        // duration is an artefact of when recording stopped.
        let flightPhases = [hopFlight, stepFlight].compactMap { $0 }
        if !flightPhases.isEmpty {
            values["Flight time"] = flightPhases.map(\.duration).reduce(0, +)
                / Double(flightPhases.count)
            confidences["Flight time"] = flightPhases.map(\.confidence).min() ?? 0
        }

        // --- Velocities ----------------------------------------------------

        var approachVelocity: Double?
        if let takeoff {
            approachVelocity = horizontalVelocity(endingAtFrame: takeoff.startFrame,
                                                  index: index)
            if let approachVelocity {
                values["Approach velocity"] = approachVelocity
                confidences["Approach velocity"] = takeoff.confidence

                if !(6.0...12.5).contains(approachVelocity) {
                    warnings.append(String(
                        format: "Approach velocity measured at %.1f m/s, which is "
                        + "outside the plausible range for a triple jump. The "
                        + "calibration or the athlete's line across the runway may "
                        + "be off.", approachVelocity))
                }
            }
        }

        if let approachVelocity, let stepLanding,
           let exitVelocity = horizontalVelocity(endingAtFrame: stepLanding.endFrame,
                                                 index: index) {
            values["Velocity loss"] = approachVelocity - exitVelocity
            confidences["Velocity loss"] = min(takeoff?.confidence ?? 0,
                                               stepLanding.confidence)
        }

        // --- Hip rise -------------------------------------------------------

        var rises = [Double]()
        for phase in flightPhases {
            guard let start = index.frame(at: phase.startFrame)?.hipCentre else { continue }
            let peak = index.frames(from: phase.startFrame, to: phase.endFrame)
                .compactMap { $0.hipCentre?.z }
                .max()
            if let peak { rises.append(peak - start.z) }
        }
        if !rises.isEmpty {
            values["Hip rise in flight"] = rises.reduce(0, +) / Double(rises.count)
            confidences["Hip rise in flight"] = flightPhases.map(\.confidence).min() ?? 0
        }

        // --- Joint angles ----------------------------------------------------

        var kneeAngles = [Double]()
        var trunkLeans = [Double]()
        for phase in landingContacts {
            guard let side = phase.side,
                  let frame = index.frame(at: phase.startFrame) else { continue }
            if let knee = JointAngles.knee(frame, side: side) { kneeAngles.append(knee) }
            if let lean = JointAngles.trunkLean(frame) { trunkLeans.append(lean) }
        }
        if !kneeAngles.isEmpty {
            values["Knee angle at touchdown"] =
                kneeAngles.reduce(0, +) / Double(kneeAngles.count)
            // Angles are additionally degraded by out-of-plane motion the
            // single camera cannot resolve, so their confidence is discounted
            // below the phase confidence that positions get.
            confidences["Knee angle at touchdown"] =
                (landingContacts.map(\.confidence).min() ?? 0) * 0.8
        }
        if !trunkLeans.isEmpty {
            values["Trunk lean at touchdown"] =
                trunkLeans.reduce(0, +) / Double(trunkLeans.count)
            confidences["Trunk lean at touchdown"] =
                (landingContacts.map(\.confidence).min() ?? 0) * 0.8
        }

        return Output(values: values, confidences: confidences, warnings: warnings)
    }

    // MARK: - Helpers

    /// Random access into the frame array by analysis frame index.
    private struct FrameIndex {
        let frames: [ReconstructedFrame]
        private let positions: [Int: Int]

        init(frames: [ReconstructedFrame]) {
            self.frames = frames
            var map = [Int: Int]()
            for (offset, frame) in frames.enumerated() {
                map[frame.frameIndex] = offset
            }
            positions = map
        }

        func frame(at frameIndex: Int) -> ReconstructedFrame? {
            guard let offset = positions[frameIndex] else { return nil }
            return frames[offset]
        }

        func frames(from start: Int, to end: Int) -> [ReconstructedFrame] {
            guard let a = positions[start], let b = positions[end], a <= b else {
                return []
            }
            return Array(frames[a...b])
        }
    }

    /// Median foot position over the stationary middle of a contact.
    ///
    /// Median rather than mean, and the trimmed middle rather than the whole
    /// contact. Both choices came out of validation: the median is immune to
    /// a single badly-placed frame, and trimming excludes the fast-moving
    /// transition frames at each boundary whose jitter dominated the variance.
    private func plantPosition(phase: PhaseSegmentation.Phase,
                               index: FrameIndex,
                               landmark: PoseLandmark? = nil) -> SIMD3<Double>? {
        guard let side = phase.side else { return nil }
        let window = index.frames(from: phase.startFrame, to: phase.endFrame)
        guard window.count >= 3 else { return nil }

        let trim = Int(Double(window.count) * options.contactTrimFraction)
        let core = window.dropFirst(trim).dropLast(trim)
        guard !core.isEmpty else { return nil }

        let landmarks = PoseLandmark.footLandmarks(side: side)
        let positions: [SIMD3<Double>] = core.compactMap { frame in
            if let landmark { return frame[landmark]?.position }
            // Lowest of heel and toe: which contacts first depends on whether
            // the athlete lands flat, heel-first or on the forefoot, and the
            // triple jump uses all three across its phases.
            let candidates = [frame[landmarks.heel], frame[landmarks.toe]]
                .compactMap { $0 }
            return candidates.min { $0.position.z < $1.position.z }?.position
        }
        guard !positions.isEmpty else { return nil }

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.count % 2 == 0
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
                : sorted[sorted.count / 2]
        }

        return SIMD3(median(positions.map(\.x)),
                     median(positions.map(\.y)),
                     median(positions.map(\.z)))
    }

    /// Horizontal hip velocity averaged over a window ending at a frame.
    ///
    /// Taken from the hips rather than a foot: the foot is stationary during
    /// stance and moving at twice body speed during swing, so its
    /// instantaneous velocity says almost nothing about how fast the athlete
    /// is travelling.
    private func horizontalVelocity(endingAtFrame frameIndex: Int,
                                    index: FrameIndex) -> Double? {
        let windowFrames = Int(options.approachWindowSeconds
                               * ProcessingTimebase.analysisRate)
        let start = frameIndex - windowFrames
        let window = index.frames(from: start, to: frameIndex)
        guard window.count >= 3 else { return nil }

        let positions = window.compactMap { frame -> (Double, Double)? in
            guard let hips = frame.hipCentre else { return nil }
            return (frame.timestamp, hips.x)
        }
        guard positions.count >= 3,
              let first = positions.first, let last = positions.last else { return nil }

        let span = last.0 - first.0
        guard span > 1e-6 else { return nil }
        return (last.1 - first.1) / span
    }
}
