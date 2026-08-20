import Foundation
import simd

public enum JumpPhase: String, Codable, CaseIterable, Sendable {
    case approach
    case hopContact, hopFlight
    case stepContact, stepFlight
    case jumpContact, jumpFlight
    case landing

    public var displayName: String {
        switch self {
        case .approach:     return "Approach"
        case .hopContact:   return "Hop take-off"
        case .hopFlight:    return "Hop flight"
        case .stepContact:  return "Step contact"
        case .stepFlight:   return "Step flight"
        case .jumpContact:  return "Jump contact"
        case .jumpFlight:   return "Jump flight"
        case .landing:      return "Landing"
        }
    }
}

public enum EventType: String, Codable, Sendable {
    case touchdown, toeOff
}

public struct GroundEvent: Sendable, Identifiable {
    public let id = UUID()
    public var type: EventType
    public var timestamp: Double
    public var frameIndex: Int
    public var side: Side
    /// Confidence in the detection, 0...1.
    public var confidence: Double
    /// True when a user has confirmed or corrected this event by hand.
    public var isManuallyConfirmed: Bool = false

    public enum Side: String, Codable, Sendable { case left, right }

    public init(type: EventType, timestamp: Double, frameIndex: Int,
                side: Side, confidence: Double, isManuallyConfirmed: Bool = false) {
        self.type = type
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.side = side
        self.confidence = confidence
        self.isManuallyConfirmed = isManuallyConfirmed
    }
}

/// Detects ground contact events from reconstructed foot trajectories.
///
/// Design priority is repeatability, not peak sensitivity. Two consequences
/// shape the algorithm:
///
/// First, all thresholds are absolute and expressed in physical units —
/// metres, metres per second, seconds — rather than being derived from the
/// clip's own statistics. A threshold set at, say, "20% of peak vertical
/// velocity in this clip" would adapt to each recording, so the same
/// technique would be scored against a slightly different bar every session.
/// Fixed physical thresholds mean the bar never moves.
///
/// Second, the detector reports confidence and defers to manual correction
/// rather than guessing hard cases. An event silently placed two frames late
/// corrupts contact time by 13 ms with no indication anything went wrong; a
/// low-confidence flag prompts a five-second check instead.
public struct EventDetector {

    public struct Thresholds: Sendable {
        /// Foot height below which contact is possible, used to find the
        /// stationary core of a contact. Generous, because the reconstructed
        /// foot height carries roughly a centimetre of error and shoes have
        /// real thickness.
        public var contactHeightMetres: Double = 0.06

        /// Tighter height threshold used to expand the contact boundaries
        /// outward from the core, for timing.
        ///
        /// The velocity gates below cannot locate the boundary: the velocity
        /// filter spans 60 ms and so smears the sharp transition at touchdown
        /// across several frames, which truncated measured contact times by
        /// about 45 ms in validation — a 36% underestimate. Height is not
        /// smeared in the same way, so boundaries are recovered from the
        /// height signal alone once the velocity gates have confirmed a real
        /// contact exists. Sweeping this value showed 0.025 m minimises the
        /// residual timing bias.
        public var boundaryHeightMetres: Double = 0.025

        /// Vertical speed below which the foot is considered planted.
        public var contactVerticalSpeed: Double = 0.35

        /// Horizontal speed below which the foot is considered planted. The
        /// foot is nearly stationary in world coordinates during stance even
        /// while the body travels fast over it.
        public var contactHorizontalSpeed: Double = 1.6

        /// Shortest credible ground contact. Elite triple jump contacts run
        /// 100–150 ms; anything under 60 ms is a detection artefact.
        public var minimumContactSeconds: Double = 0.060

        /// Longest credible contact before it must be the landing.
        public var maximumContactSeconds: Double = 0.320

        /// Shortest credible flight phase.
        public var minimumFlightSeconds: Double = 0.150

        public init() {}
    }

    public var thresholds = Thresholds()

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// Per-frame contact signal for one foot.
    private struct ContactSignal {
        var height: [Double]
        var verticalSpeed: [Double]
        var horizontalSpeed: [Double]
        var confidence: [Double]
        /// Whether this side was seen in even one frame.
        ///
        /// Distinguishes "the foot was never observed" from "the foot was
        /// observed on the ground", which the height signal alone cannot:
        /// `fillGaps` turns an all-missing signal into a constant zero, and
        /// zero height at zero speed satisfies every contact gate there is.
        var wasObserved: Bool
    }

    private func buildSignal(frames: [ReconstructedFrame],
                             side: GroundEvent.Side) -> ContactSignal {
        let heelLandmark: PoseLandmark = side == .left ? .leftHeel : .rightHeel
        let toeLandmark: PoseLandmark = side == .left ? .leftFootIndex : .rightFootIndex
        let ankleLandmark: PoseLandmark = side == .left ? .leftAnkle : .rightAnkle

        var heights = [Double](), xs = [Double](), confs = [Double]()

        for frame in frames {
            // Lowest of heel and toe: which one contacts first depends on
            // whether the athlete lands flat, heel-first, or on the forefoot,
            // and triple jump uses all three across the phases.
            var candidates = [(SIMD3<Double>, Double)]()
            if let heel = frame[heelLandmark] { candidates.append((heel.position, heel.confidence)) }
            if let toe = frame[toeLandmark] { candidates.append((toe.position, toe.confidence)) }

            if candidates.isEmpty, let ankle = frame[ankleLandmark] {
                // Ankle fallback: sits about 8 cm above the ground at contact,
                // so subtract that offset rather than treating it as the sole.
                candidates.append((ankle.position - SIMD3(0, 0, 0.08),
                                   ankle.confidence * 0.7))
            }

            if let lowest = candidates.min(by: { $0.0.z < $1.0.z }) {
                heights.append(lowest.0.z)
                xs.append(lowest.0.x)
                confs.append(lowest.1)
            } else {
                heights.append(.nan)
                xs.append(.nan)
                confs.append(0)
            }
        }

        // Fill gaps so the derivative filter has continuous input.
        let filledHeights = fillGaps(heights)
        let filledXs = fillGaps(xs)

        let velocityFilter = ProcessingTimebase.velocityFilter
        let dt = ProcessingTimebase.sampleInterval
        let vz = velocityFilter.apply(filledHeights, derivative: 1, sampleInterval: dt)
        let vx = velocityFilter.apply(filledXs, derivative: 1, sampleInterval: dt)

        return ContactSignal(height: filledHeights,
                             verticalSpeed: vz.map(abs),
                             horizontalSpeed: vx.map(abs),
                             confidence: confs,
                             wasObserved: heights.contains { !$0.isNaN })
    }

    private func fillGaps(_ values: [Double]) -> [Double] {
        var out = values
        guard let firstValid = out.firstIndex(where: { !$0.isNaN }) else {
            return [Double](repeating: 0, count: out.count)
        }
        for i in 0..<firstValid { out[i] = out[firstValid] }
        var lastValid = firstValid
        for i in (firstValid + 1)..<out.count {
            if out[i].isNaN {
                // Hold the last value; interpolation across a long gap would
                // invent a trajectory the athlete never followed.
                out[i] = out[lastValid]
            } else {
                if i > lastValid + 1 {
                    let span = Double(i - lastValid)
                    for j in (lastValid + 1)..<i {
                        let a = Double(j - lastValid) / span
                        out[j] = out[lastValid] * (1 - a) + out[i] * a
                    }
                }
                lastValid = i
            }
        }
        return out
    }

    /// A detected contact, carrying two distinct index ranges.
    ///
    /// The distinction is not cosmetic. Validation showed that taking the
    /// plant position from the expanded start index inflated the variance of
    /// phase distances from 5 mm to 228 mm, because that index sits in the
    /// transition where the foot is still travelling several metres per
    /// second, so one frame of jitter moves it centimetres. The core range is
    /// stationary by construction, so a median over it is stable.
    public struct Contact: Sendable {
        /// Velocity-gated range where the foot is genuinely planted and
        /// stationary. Used for POSITION.
        public var coreRange: ClosedRange<Int>
        /// Height-expanded range covering the full contact. Used for TIMING.
        public var expandedRange: ClosedRange<Int>
        public var touchdownTime: Double
        public var toeOffTime: Double
        public var confidence: Double

        public var duration: Double { toeOffTime - touchdownTime }
    }

    /// Detect contacts for one foot.
    private func contacts(signal: ContactSignal,
                          frames: [ReconstructedFrame]) -> [Contact] {

        // --- Stage 1: find stationary cores -----------------------------
        // All three gates must hold. The velocity gates are what prevent a
        // foot passing low and fast during swing from registering as contact.
        var isCore = [Bool](repeating: false, count: frames.count)
        for i in 0..<frames.count {
            isCore[i] = signal.height[i] < thresholds.contactHeightMetres
                     && signal.verticalSpeed[i] < thresholds.contactVerticalSpeed
                     && signal.horizontalSpeed[i] < thresholds.contactHorizontalSpeed
        }

        // Close single-frame dropouts. A 6.7 ms gap is noise, never flight.
        for i in 1..<max(frames.count - 1, 1) where !isCore[i] {
            if isCore[i - 1] && isCore[i + 1] { isCore[i] = true }
        }

        var cores = [ClosedRange<Int>]()
        var runStart: Int?
        for i in 0..<frames.count {
            if isCore[i] && runStart == nil {
                runStart = i
            } else if !isCore[i], let start = runStart {
                if i - 1 > start { cores.append(start...(i - 1)) }
                runStart = nil
            }
        }
        if let start = runStart, frames.count - 1 > start {
            cores.append(start...(frames.count - 1))
        }

        // --- Stage 2: expand each core for timing -----------------------
        var results = [Contact]()

        for core in cores {
            var expandedStart = core.lowerBound
            var expandedEnd = core.upperBound

            while expandedStart > 0,
                  signal.height[expandedStart - 1] < thresholds.boundaryHeightMetres {
                expandedStart -= 1
            }
            while expandedEnd < frames.count - 1,
                  signal.height[expandedEnd + 1] < thresholds.boundaryHeightMetres {
                expandedEnd += 1
            }

            let touchdown = refineCrossing(signal: signal, frames: frames,
                                           inside: expandedStart, outside: expandedStart - 1)
            let toeOff = refineCrossing(signal: signal, frames: frames,
                                        inside: expandedEnd, outside: expandedEnd + 1)

            let duration = toeOff - touchdown
            guard duration >= thresholds.minimumContactSeconds else { continue }

            let confidences = core.map { signal.confidence[$0] }
            var confidence = confidences.reduce(0, +) / Double(confidences.count)

            // Penalise durations outside the physiological range: usually a
            // merged double-contact or a truncated one.
            if duration > thresholds.maximumContactSeconds { confidence *= 0.6 }

            // Penalise interpolated frames — a boundary may have been placed
            // on invented data.
            let range = expandedStart...expandedEnd
            let interpolated = range.filter { frames[$0].isInterpolated }.count
            confidence *= 1.0 - Double(interpolated) / Double(range.count) * 0.5

            results.append(Contact(coreRange: core,
                                   expandedRange: range,
                                   touchdownTime: touchdown,
                                   toeOffTime: toeOff,
                                   confidence: confidence))
        }

        return results
    }

    /// Sub-frame boundary refinement by linear interpolation of the height
    /// signal across the threshold.
    ///
    /// The frame grid quantises events to 6.7 ms, which at a 9 m/s approach
    /// is 60 mm of travel. Interpolating the crossing recovers part of that,
    /// and being a fixed calculation it costs nothing in repeatability.
    private func refineCrossing(signal: ContactSignal,
                                frames: [ReconstructedFrame],
                                inside: Int,
                                outside: Int) -> Double {
        guard outside >= 0, outside < frames.count else {
            return frames[inside].timestamp
        }
        let threshold = thresholds.boundaryHeightMetres
        let hOut = signal.height[outside], hIn = signal.height[inside]
        guard abs(hIn - hOut) > 1e-9,
              min(hOut, hIn) <= threshold, threshold <= max(hOut, hIn) else {
            return frames[inside].timestamp
        }
        let alpha = (threshold - hOut) / (hIn - hOut)
        let tOut = frames[outside].timestamp, tIn = frames[inside].timestamp
        return tOut + alpha * (tIn - tOut)
    }

    /// Plant position for a contact: the median position across its
    /// stationary core.
    ///
    /// Median rather than mean, and core rather than expanded range. Both
    /// choices came out of validation: the median is immune to a single
    /// badly-placed frame, and the core excludes the fast-moving transition
    /// frames whose jitter dominated the variance.
    public static func plantPosition(contact: Contact,
                                     frames: [ReconstructedFrame],
                                     landmark: PoseLandmark) -> SIMD3<Double>? {
        let positions = contact.coreRange.compactMap { index -> SIMD3<Double>? in
            guard index < frames.count else { return nil }
            return frames[index][landmark]?.position
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

    /// Detected contacts with their side, retained so the metrics engine can
    /// use the stationary core for position measurements.
    public struct SidedContact: Sendable {
        public var contact: Contact
        public var side: GroundEvent.Side
    }

    /// Detect all contacts across the trial.
    public func detectContacts(frames: [ReconstructedFrame]) -> [SidedContact] {
        guard frames.count >= 10 else { return [] }

        var results = [SidedContact]()
        for side in [GroundEvent.Side.left, .right] {
            let signal = buildSignal(frames: frames, side: side)
            // A side with no observations anywhere in the clip yields no
            // contacts. Without this the zero-filled signal reads as a single
            // motionless contact spanning the whole recording — at height 0
            // and speed 0 it passes every gate, and it is emitted with
            // confidence 0 rather than rejected, so it reaches segmentation
            // as a real phase boundary.
            guard signal.wasObserved else { continue }
            for contact in contacts(signal: signal, frames: frames) {
                results.append(SidedContact(contact: contact, side: side))
            }
        }
        return results.sorted { $0.contact.touchdownTime < $1.contact.touchdownTime }
    }

    /// Detect all ground events across the trial.
    public func detectEvents(frames: [ReconstructedFrame]) -> [GroundEvent] {
        detectContacts(frames: frames).flatMap { sided -> [GroundEvent] in
            let c = sided.contact
            return [
                GroundEvent(type: .touchdown,
                            timestamp: c.touchdownTime,
                            frameIndex: frames[c.expandedRange.lowerBound].frameIndex,
                            side: sided.side,
                            confidence: c.confidence),
                GroundEvent(type: .toeOff,
                            timestamp: c.toeOffTime,
                            frameIndex: frames[c.expandedRange.upperBound].frameIndex,
                            side: sided.side,
                            confidence: c.confidence),
            ]
        }.sorted { $0.timestamp < $1.timestamp }
    }
}

/// A segmented trial: the three phases identified from the event sequence.
public struct PhaseSegmentation: Sendable {

    public struct Phase: Sendable {
        public var phase: JumpPhase
        public var startTime: Double
        public var endTime: Double
        public var startFrame: Int
        public var endFrame: Int
        public var side: GroundEvent.Side?
        public var confidence: Double

        public var duration: Double { endTime - startTime }
    }

    public var phases: [Phase]
    public var boardContact: GroundEvent?
    public var overallConfidence: Double
    public var warnings: [String]

    public var requiresManualReview: Bool {
        overallConfidence < 0.7 || !warnings.isEmpty
    }
}

/// Turns a raw event list into hop/step/jump phases.
///
/// The triple jump has a fixed, known structure that heavily constrains the
/// answer: take-off and hop landing are on the same foot, the step lands on
/// the opposite foot, and the jump takes off from that opposite foot. Rather
/// than trusting the raw detections, the segmenter finds the event sequence
/// most consistent with that structure. A single missed toe-off is then
/// recoverable from context instead of derailing the whole segmentation.
public struct PhaseSegmenter {

    public init() {}

    public func segment(events: [GroundEvent],
                        frames: [ReconstructedFrame],
                        boardScratchLineX: Double = 0.0) -> PhaseSegmentation {

        var warnings = [String]()

        // Pair touchdowns with their following toe-off on the same side.
        var contacts = [(td: GroundEvent, to: GroundEvent)]()
        for event in events where event.type == .touchdown {
            if let toeOff = events.first(where: {
                $0.type == .toeOff && $0.side == event.side
                    && $0.timestamp > event.timestamp
            }) {
                contacts.append((event, toeOff))
            }
        }

        guard contacts.count >= 3 else {
            warnings.append("Only \(contacts.count) ground contacts found; "
                          + "at least 3 are needed. Check the athlete stays in frame "
                          + "for the whole jump.")
            return PhaseSegmentation(phases: [], boardContact: nil,
                                     overallConfidence: 0, warnings: warnings)
        }

        // The board contact is the last one at or before the scratch line.
        // Approaching from negative X, take-off happens near X = 0.
        var boardContactIndex: Int?
        for (i, contact) in contacts.enumerated() {
            guard let frame = frames.first(where: { $0.frameIndex == contact.td.frameIndex }),
                  let toe = frame[contact.td.side == .left ? .leftFootIndex : .rightFootIndex]
            else { continue }
            if toe.position.x <= boardScratchLineX + 0.15 {
                boardContactIndex = i
            }
        }

        guard let boardIndex = boardContactIndex,
              boardIndex + 2 < contacts.count else {
            warnings.append("Could not identify the take-off contact on the board. "
                          + "Confirm the board corners were tapped correctly.")
            return PhaseSegmentation(phases: [], boardContact: contacts.first?.td,
                                     overallConfidence: 0, warnings: warnings)
        }

        let takeoff = contacts[boardIndex]
        let hopLanding = contacts[boardIndex + 1]
        let stepLanding = contacts[boardIndex + 2]

        // Structural check. The hop must land on the take-off foot and the
        // step on the other; a violation means a contact was missed or a side
        // was misassigned, and the numbers downstream would be nonsense.
        if hopLanding.td.side != takeoff.td.side {
            warnings.append("Hop appears to land on the opposite foot from take-off, "
                          + "which is not a legal triple jump. Left/right assignment "
                          + "is likely wrong — review the detected events.")
        }
        if stepLanding.td.side == hopLanding.td.side {
            warnings.append("Step appears to land on the same foot as the hop. "
                          + "A contact was probably missed.")
        }

        var phases = [PhaseSegmentation.Phase]()

        phases.append(.init(phase: .hopContact,
                            startTime: takeoff.td.timestamp,
                            endTime: takeoff.to.timestamp,
                            startFrame: takeoff.td.frameIndex,
                            endFrame: takeoff.to.frameIndex,
                            side: takeoff.td.side,
                            confidence: min(takeoff.td.confidence, takeoff.to.confidence)))

        phases.append(.init(phase: .hopFlight,
                            startTime: takeoff.to.timestamp,
                            endTime: hopLanding.td.timestamp,
                            startFrame: takeoff.to.frameIndex,
                            endFrame: hopLanding.td.frameIndex,
                            side: nil,
                            confidence: min(takeoff.to.confidence, hopLanding.td.confidence)))

        phases.append(.init(phase: .stepContact,
                            startTime: hopLanding.td.timestamp,
                            endTime: hopLanding.to.timestamp,
                            startFrame: hopLanding.td.frameIndex,
                            endFrame: hopLanding.to.frameIndex,
                            side: hopLanding.td.side,
                            confidence: min(hopLanding.td.confidence, hopLanding.to.confidence)))

        phases.append(.init(phase: .stepFlight,
                            startTime: hopLanding.to.timestamp,
                            endTime: stepLanding.td.timestamp,
                            startFrame: hopLanding.to.frameIndex,
                            endFrame: stepLanding.td.frameIndex,
                            side: nil,
                            confidence: min(hopLanding.to.confidence, stepLanding.td.confidence)))

        phases.append(.init(phase: .jumpContact,
                            startTime: stepLanding.td.timestamp,
                            endTime: stepLanding.to.timestamp,
                            startFrame: stepLanding.td.frameIndex,
                            endFrame: stepLanding.to.frameIndex,
                            side: stepLanding.td.side,
                            confidence: min(stepLanding.td.confidence, stepLanding.to.confidence)))

        if let last = frames.last {
            phases.append(.init(phase: .jumpFlight,
                                startTime: stepLanding.to.timestamp,
                                endTime: last.timestamp,
                                startFrame: stepLanding.to.frameIndex,
                                endFrame: last.frameIndex,
                                side: nil,
                                confidence: stepLanding.to.confidence))
        }

        let confidences = phases.map(\.confidence)
        let overall = confidences.isEmpty ? 0
            : confidences.reduce(0, +) / Double(confidences.count)

        // Sanity-check phase durations against physiology.
        for phase in phases {
            switch phase.phase {
            case .hopContact, .stepContact, .jumpContact:
                if phase.duration > 0.35 {
                    warnings.append("\(phase.phase.displayName) lasts "
                        + "\(Int(phase.duration * 1000)) ms, which is unusually long. "
                        + "The toe-off may have been detected late.")
                }
            case .hopFlight, .stepFlight:
                if phase.duration < 0.15 {
                    warnings.append("\(phase.phase.displayName) lasts only "
                        + "\(Int(phase.duration * 1000)) ms, which is unusually short. "
                        + "A contact may have been detected early.")
                }
            default:
                break
            }
        }

        return PhaseSegmentation(phases: phases,
                                 boardContact: takeoff.td,
                                 overallConfidence: overall,
                                 warnings: warnings)
    }
}
