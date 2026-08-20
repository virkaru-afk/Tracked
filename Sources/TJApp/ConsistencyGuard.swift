import Foundation

/// Everything that must match for two sessions to be directly comparable.
///
/// The premise of this tool is that a coach can say "your hop contact time
/// dropped 12 ms since last month" and have that mean something. That claim
/// only holds if the two measurements were produced under equivalent
/// conditions. This type records the conditions and makes mismatches explicit
/// rather than letting incomparable numbers sit side by side in a chart.
public struct ComparabilityKey: Codable, Equatable, Sendable {

    /// Which calibration profile produced the measurements. Two profiles are
    /// two different rulers, even when they describe the same physical spot.
    public var calibrationProfileID: UUID

    /// Capture configuration fingerprint.
    public var captureFingerprint: String

    /// Actual delivered frame rate, rounded to the nearest whole number.
    public var measuredFrameRate: Int

    /// Version of the analysis pipeline. Changing a filter window or a
    /// detection threshold changes the numbers, so results from different
    /// pipeline versions must not be silently compared.
    public var pipelineVersion: String

    public init(calibrationProfileID: UUID,
                captureFingerprint: String,
                measuredFrameRate: Int,
                pipelineVersion: String = AnalysisPipeline.version) {
        self.calibrationProfileID = calibrationProfileID
        self.captureFingerprint = captureFingerprint
        self.measuredFrameRate = measuredFrameRate
        self.pipelineVersion = pipelineVersion
    }
}

/// Identifies the analysis pipeline configuration.
public enum AnalysisPipeline {

    /// Bump on any change that alters output values: filter windows,
    /// detection thresholds, reconstruction method, smoothing order.
    public static let version = "1.0.0"

    /// The parameters that define this version, recorded so an old session
    /// can be re-analysed under its original settings when the pipeline moves
    /// on. Without this, upgrading the app would silently invalidate a
    /// season's worth of history.
    public static var parameterSnapshot: [String: String] {
        [
            "analysisRate": "\(ProcessingTimebase.analysisRate)",
            "positionWindowMs": "\(ProcessingTimebase.Window.positionMilliseconds)",
            "velocityWindowMs": "\(ProcessingTimebase.Window.velocityMilliseconds)",
            "accelerationWindowMs": "\(ProcessingTimebase.Window.accelerationMilliseconds)",
            "contactHeightM": "\(EventDetector.Thresholds().contactHeightMetres)",
            "contactVerticalSpeed": "\(EventDetector.Thresholds().contactVerticalSpeed)",
            "contactHorizontalSpeed": "\(EventDetector.Thresholds().contactHorizontalSpeed)",
            "minContactS": "\(EventDetector.Thresholds().minimumContactSeconds)",
        ]
    }
}

/// Outcome of the pre-analysis checks.
public struct ConsistencyCheck: Sendable {

    public enum Verdict: Sendable, Equatable {
        /// Safe to analyse and to compare against history on this profile.
        case comparable

        /// Analysable, but something differs from the profile's history.
        /// Results are shown with a marker rather than blended into trends.
        case analysableNotComparable(reasons: [String])

        /// Should not be analysed: the result would be misleading.
        case reject(reasons: [String])
    }

    public var verdict: Verdict
    public var key: ComparabilityKey?
    public var notes: [String]

    public var canProceed: Bool {
        if case .reject = verdict { return false }
        return true
    }
}

/// Pre-analysis gate.
///
/// Deliberately conservative. A refusal to analyse costs a coach one retake;
/// a wrong number that looks plausible can send an athlete's training in the
/// wrong direction for weeks. Where the two errors trade off, this errs
/// toward refusing.
public struct ConsistencyGuard {

    public struct Limits: Sendable {
        /// Below this, ground-contact timing degrades past usefulness. At
        /// 100 fps a 110 ms step contact yields only eleven samples, and the
        /// boundary frames dominate the measurement.
        public var minimumFrameRate: Double = 120

        /// Frame rate must match the profile's history within this, or the
        /// effective temporal resolution differs.
        public var frameRateTolerance: Double = 5

        /// Maximum share of frames where pose confidence is too low.
        public var maximumLowConfidenceFraction: Double = 0.15

        /// Minimum mean pose confidence across analysed landmarks.
        public var minimumMeanConfidence: Double = 0.55

        /// Calibration profiles older than this should be re-verified. Not
        /// re-solved — verified. Tripods drift, floor tape peels, someone
        /// moves the pipe.
        public var verificationIntervalDays: Int = 30

        /// How far the lens may sit from its calibrated position, on the
        /// 0-to-1 scale iOS reports, before the recording is rejected.
        ///
        /// Deliberately tight. `setFocusModeLockedWithLensPosition` should
        /// reproduce the stored value essentially exactly, so anything beyond
        /// rounding means the lens was not actually pinned where it was
        /// asked to be — the device refused the request, or something reset
        /// it between configuration and recording. Both are worth stopping
        /// for, because neither is visible in the footage.
        public var maximumLensPositionDrift: Double = 0.02

        public init() {}
    }

    public var limits = Limits()

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// - Parameter recordedLensPosition: Focus position the clip was actually
    ///   shot at, from `CaptureController.currentLensPosition`. Compared
    ///   against the profile's, because focal length moves with focus and the
    ///   mode fingerprint cannot see the difference.
    public func check(profile: CalibrationProfile,
                      captureConfiguration: CaptureConfiguration,
                      measuredFrameRate: Double,
                      poseFrames: [PoseFrame],
                      previousSessionKeys: [ComparabilityKey] = [],
                      recordedLensPosition: Double? = nil) -> ConsistencyCheck {

        var rejections = [String]()
        var incomparabilities = [String]()
        var notes = [String]()

        // --- Hard rejections -------------------------------------------

        if measuredFrameRate < limits.minimumFrameRate {
            rejections.append(
                "Recorded at \(Int(measuredFrameRate)) fps. At least "
                + "\(Int(limits.minimumFrameRate)) fps is needed to time ground "
                + "contacts reliably. Check that slow-motion mode is enabled and "
                + "that lighting is bright enough to sustain the frame rate.")
        }

        if captureConfiguration.fingerprint != profile.intrinsics.configurationFingerprint {
            rejections.append(
                "This recording used a different camera configuration than the "
                + "calibration profile. Lens calibration does not transfer between "
                + "configurations, so measurements would be scaled incorrectly.")
        }

        // Focus position. The fingerprint covers device, resolution and frame
        // rate — all identical whether the lens is focused at half a metre or
        // at infinity — while focal length is not. Two calibrations that look
        // interchangeable by fingerprint can therefore scale distances
        // differently, which is precisely the class of silent error the
        // fingerprint exists to prevent, arriving through the one door it
        // does not cover.
        switch (profile.intrinsics.lensPosition, recordedLensPosition) {
        case let (calibrated?, recorded?):
            let drift = abs(calibrated - recorded)
            if drift > limits.maximumLensPositionDrift {
                rejections.append(
                    "The lens focused differently for this recording than for "
                    + "the calibration (\(String(format: "%.2f", recorded)) "
                    + "versus \(String(format: "%.2f", calibrated))). Focal "
                    + "length changes with focus, so every distance would be "
                    + "scaled by an amount nothing downstream can detect.")
            }
        case (nil, _):
            notes.append(
                "This calibration profile predates focus-position tracking, so "
                + "there is no way to confirm the recording was shot at the "
                + "focal length that was calibrated. Re-run the lens "
                + "calibration to remove the doubt.")
        case (_?, nil):
            notes.append(
                "The focus position of this recording was not captured, so it "
                + "could not be checked against the calibration.")
        }

        if poseFrames.isEmpty {
            rejections.append("No pose data was extracted from this recording.")
        } else {
            let lowConfidence = poseFrames.filter {
                $0.analysisConfidence < limits.minimumMeanConfidence
            }
            let fraction = Double(lowConfidence.count) / Double(poseFrames.count)
            if fraction > limits.maximumLowConfidenceFraction {
                rejections.append(
                    "Body tracking was unreliable in \(Int(fraction * 100))% of frames. "
                    + "Common causes are motion blur from low light, the athlete "
                    + "leaving frame, or someone crossing between camera and runway.")
            }
        }

        // --- Comparability warnings ------------------------------------

        let daysSinceVerification = Calendar.current.dateComponents(
            [.day], from: profile.lastVerifiedAt, to: Date()).day ?? 0
        if daysSinceVerification > limits.verificationIntervalDays {
            notes.append(
                "This calibration was last verified \(daysSinceVerification) days ago. "
                + "Re-tapping the reference points takes about 20 seconds and confirms "
                + "nothing has shifted.")
        }

        let roundedRate = Int(measuredFrameRate.rounded())
        for previous in previousSessionKeys
        where previous.calibrationProfileID == profile.id {
            if abs(Double(previous.measuredFrameRate) - measuredFrameRate)
                > limits.frameRateTolerance {
                incomparabilities.append(
                    "Earlier sessions on this profile ran at "
                    + "\(previous.measuredFrameRate) fps; this one is at \(roundedRate) fps. "
                    + "Timing measurements are not directly comparable.")
                break
            }
        }

        for previous in previousSessionKeys
        where previous.pipelineVersion != AnalysisPipeline.version {
            incomparabilities.append(
                "Earlier sessions were analysed with pipeline "
                + "\(previous.pipelineVersion); this one uses "
                + "\(AnalysisPipeline.version). Re-analyse the earlier sessions to "
                + "restore direct comparison.")
            break
        }

        if profile.reprojectionRMSE > CalibrationQuality.excellentRMSE {
            notes.append(
                "This profile's calibration fit is "
                + String(format: "%.1f", profile.reprojectionRMSE)
                + " px. Absolute distances carry a corresponding scale error, but "
                + "session-to-session comparisons on this profile are unaffected, "
                + "because the same error applies to every session equally.")
        }

        // --- Verdict ----------------------------------------------------

        let key = ComparabilityKey(calibrationProfileID: profile.id,
                                   captureFingerprint: captureConfiguration.fingerprint,
                                   measuredFrameRate: roundedRate)

        if !rejections.isEmpty {
            return ConsistencyCheck(verdict: .reject(reasons: rejections),
                                    key: nil, notes: notes)
        }
        if !incomparabilities.isEmpty {
            return ConsistencyCheck(verdict: .analysableNotComparable(reasons: incomparabilities),
                                    key: key, notes: notes)
        }
        return ConsistencyCheck(verdict: .comparable, key: key, notes: notes)
    }
}

/// A stored session result.
public struct SessionRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public var athleteName: String
    public var date: Date
    public var key: ComparabilityKey
    public var videoURL: URL?

    /// Metric values keyed by name, for trend comparison.
    public var metricValues: [String: Double]
    public var metricConfidences: [String: Double]

    /// Whether a human reviewed and confirmed the detected events. Sessions
    /// with confirmed events carry more weight in trends, because manual
    /// confirmation removes the dominant source of run-to-run variation.
    public var eventsManuallyConfirmed: Bool

    public var notes: String

    public init(id: UUID = UUID(),
                athleteName: String,
                date: Date = Date(),
                key: ComparabilityKey,
                videoURL: URL? = nil,
                metricValues: [String: Double] = [:],
                metricConfidences: [String: Double] = [:],
                eventsManuallyConfirmed: Bool = false,
                notes: String = "") {
        self.id = id
        self.athleteName = athleteName
        self.date = date
        self.key = key
        self.videoURL = videoURL
        self.metricValues = metricValues
        self.metricConfidences = metricConfidences
        self.eventsManuallyConfirmed = eventsManuallyConfirmed
        self.notes = notes
    }
}

/// Compares sessions, refusing to compare ones that are not comparable.
public struct TrendAnalyser {

    public init() {}

    public struct Comparison: Sendable {
        public var metricName: String
        public var currentValue: Double
        public var previousValue: Double
        public var change: Double
        public var percentChange: Double
        /// Whether the change exceeds the measurement noise for this metric.
        public var isMeaningful: Bool
        public var interpretation: String
    }

    /// Smallest change worth reporting, per metric, in that metric's units.
    ///
    /// These come from the validated error model rather than being picked for
    /// looks. Reporting a 3 ms change in contact time when the measurement
    /// resolution is 7 ms would be presenting noise as progress, which is the
    /// specific failure this whole design is built to avoid.
    public static let meaningfulChangeThresholds: [String: Double] = [
        // Contact time sits at 15 ms rather than 10: validation measured a
        // 5.0 ms run-to-run SD, and a 10 ms threshold is only twice that,
        // which would surface noise as change roughly one time in twenty.
        "Contact time": 15.0,                        // ms, ~3x measured SD
        "Flight time": 15.0,                         // ms
        "Hop distance": 0.030,                       // m
        "Step distance": 0.030,                      // m
        "Touchdown distance ahead of hips": 0.025,   // m
        "Approach velocity": 0.15,                   // m/s
        "Velocity loss": 0.15,                       // m/s
        "Hip rise in flight": 0.040,                 // m
        "Knee angle at touchdown": 4.0,              // degrees
        "Trunk lean at touchdown": 4.0,              // degrees
        "Hop share of measured phases": 2.0,         // percent
        "Step share of measured phases": 2.0,        // percent
        "Toe distance behind scratch line": 0.025,   // m
    ]

    public enum ComparisonError: Error, LocalizedError {
        case differentCalibrationProfile
        case differentPipelineVersion
        case differentFrameRate

        public var errorDescription: String? {
            switch self {
            case .differentCalibrationProfile:
                return "These sessions used different calibration profiles and cannot "
                     + "be compared directly. Each profile is effectively a different "
                     + "ruler."
            case .differentPipelineVersion:
                return "These sessions were analysed with different pipeline versions. "
                     + "Re-analyse the older one to compare."
            case .differentFrameRate:
                return "These sessions were recorded at different frame rates, so "
                     + "timing measurements are not directly comparable."
            }
        }
    }

    public func compare(current: SessionRecord,
                        previous: SessionRecord) throws -> [Comparison] {

        guard current.key.calibrationProfileID == previous.key.calibrationProfileID
        else { throw ComparisonError.differentCalibrationProfile }

        guard current.key.pipelineVersion == previous.key.pipelineVersion
        else { throw ComparisonError.differentPipelineVersion }

        guard abs(current.key.measuredFrameRate - previous.key.measuredFrameRate) <= 5
        else { throw ComparisonError.differentFrameRate }

        var comparisons = [Comparison]()

        for (name, currentValue) in current.metricValues {
            guard let previousValue = previous.metricValues[name] else { continue }

            let change = currentValue - previousValue
            let percent = abs(previousValue) > 1e-9
                ? change / abs(previousValue) * 100 : 0

            let baseThreshold = Self.meaningfulChangeThresholds[name]
                ?? abs(previousValue) * 0.05

            // Widen the threshold when either session had weak detection.
            // A change measured on shaky data needs to be larger before it
            // can be distinguished from the measurement itself.
            let currentConfidence = current.metricConfidences[name] ?? 1.0
            let previousConfidence = previous.metricConfidences[name] ?? 1.0
            let confidencePenalty = 1.0 / max(min(currentConfidence, previousConfidence), 0.3)
            let threshold = baseThreshold * confidencePenalty

            let meaningful = abs(change) > threshold

            let interpretation: String
            if meaningful {
                interpretation = String(format: "Changed by %.3g (threshold %.3g)",
                                        abs(change), threshold)
            } else {
                interpretation = "Within measurement noise — not a real change"
            }

            comparisons.append(Comparison(metricName: name,
                                          currentValue: currentValue,
                                          previousValue: previousValue,
                                          change: change,
                                          percentChange: percent,
                                          isMeaningful: meaningful,
                                          interpretation: interpretation))
        }

        return comparisons.sorted { $0.metricName < $1.metricName }
    }
}
