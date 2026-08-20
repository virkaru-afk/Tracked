import Foundation
import AVFoundation

/// Extracts 2D body pose from a recorded clip.
///
/// A protocol so the pipeline can be exercised without MediaPipe present.
/// The real implementation lives in `PoseEstimator.swift`, compiled away
/// behind `#if canImport(MediaPipeTasksVision)` until the pod is added.
public protocol PoseExtracting: Sendable {
    /// Extract pose for every frame of the clip at `url`.
    ///
    /// `progress` is called on an arbitrary queue with a 0...1 fraction.
    /// Extraction over a 120–240 fps clip is hundreds of inferences and
    /// takes tens of seconds; a progress-free version of this call would
    /// look like a hang.
    func extractPose(from url: URL,
                     progress: @Sendable (Double) -> Void) async throws -> [PoseFrame]
}

public enum AnalysisError: Error, LocalizedError {
    case profileMissing(UUID)
    case poseArchiveMissing(UUID)
    case rejected([String])
    case noPoseExtractor

    public var errorDescription: String? {
        switch self {
        case .profileMissing:
            return "The calibration profile this session was recorded against is no "
                 + "longer available, so it cannot be re-analysed."
        case .poseArchiveMissing:
            return "The body tracking data for this session is missing, so it cannot "
                 + "be re-analysed. The measurements from the original analysis are "
                 + "unchanged."
        case .rejected(let reasons):
            return reasons.joined(separator: "\n\n")
        case .noPoseExtractor:
            return "Body tracking is not available in this build. Add the MediaPipe "
                 + "pod and the pose_landmarker_heavy.task model to enable analysis."
        }
    }
}

/// Runs the analysis pipeline, and re-runs it from corrected events.
///
/// The pipeline in order:
///
///   clip → pose extraction → consistency gate → 3D reconstruction →
///   event detection → phase segmentation → metrics → stored session
///
/// Re-analysis skips the first two stages entirely. It reads the archived 2D
/// pose, reconstructs, and then *uses the events it was given* rather than
/// detecting fresh ones. That distinction is the point of the whole event
/// correction screen: once a human has confirmed where a contact is, the
/// detector must not be allowed to move it back on the next run, or the
/// confirmation would not survive a pipeline upgrade.
public struct AnalysisRunner: EventReanalysing {

    private let sessionStore: SessionStore
    private let profileStore: CalibrationProfileStore
    private let poseExtractor: PoseExtracting?

    public init(sessionStore: SessionStore,
                profileStore: CalibrationProfileStore,
                poseExtractor: PoseExtracting? = nil) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.poseExtractor = poseExtractor
    }

    // MARK: - First analysis

    public struct AnalysisProgress: Sendable {
        public var stage: String
        public var fraction: Double
    }

    /// Analyse a freshly recorded clip and persist the result.
    public func analyse(clip: CapturedClip,
                        profile: CalibrationProfile,
                        athleteName: String,
                        notes: String = "",
                        progress: @Sendable @escaping (AnalysisProgress) -> Void = { _ in })
        async throws -> StoredSession {

        guard let poseExtractor else { throw AnalysisError.noPoseExtractor }

        // --- Pose extraction ---------------------------------------------
        progress(AnalysisProgress(stage: "Tracking body position", fraction: 0))
        let poseFrames = try await poseExtractor.extractPose(from: clip.url) { fraction in
            progress(AnalysisProgress(stage: "Tracking body position",
                                      fraction: fraction * 0.6))
        }

        // --- Consistency gate ---------------------------------------------
        progress(AnalysisProgress(stage: "Checking consistency", fraction: 0.62))

        let configuration = CaptureConfiguration(
            deviceModel: CaptureConfiguration.currentDeviceModel,
            width: profile.intrinsics.imageWidth,
            height: profile.intrinsics.imageHeight,
            frameRate: clip.measuredFrameRate)

        let previousKeys = (try? await sessionStore.loadAll())?
            .map(\.record.key) ?? []

        let check = ConsistencyGuard().check(profile: profile,
                                             captureConfiguration: configuration,
                                             measuredFrameRate: clip.measuredFrameRate,
                                             poseFrames: poseFrames,
                                             previousSessionKeys: previousKeys,
                                             recordedLensPosition: clip.lensPosition)

        guard check.canProceed, let key = check.key else {
            if case .reject(let reasons) = check.verdict {
                throw AnalysisError.rejected(reasons)
            }
            throw AnalysisError.rejected(["This recording cannot be analysed."])
        }

        // --- Reconstruction, detection, segmentation, metrics -------------
        progress(AnalysisProgress(stage: "Measuring", fraction: 0.7))

        let outcome = try runPipeline(poseFrames: poseFrames,
                                      profile: profile,
                                      deliveredFrameRate: clip.measuredFrameRate,
                                      events: nil)

        // --- Assemble and persist ------------------------------------------
        progress(AnalysisProgress(stage: "Saving", fraction: 0.92))

        let id = UUID()
        let (destination, filename) = await sessionStore.reserveVideoURL(for: id)
        if clip.url != destination {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: clip.url, to: destination)
        }

        let trialNumber = (try? await sessionStore.nextTrialNumber(athlete: athleteName,
                                                                   on: Date())) ?? 1

        var record = SessionRecord(id: id,
                                   athleteName: athleteName,
                                   key: key,
                                   metricValues: outcome.metricValues,
                                   metricConfidences: outcome.metricConfidences,
                                   eventsManuallyConfirmed: false,
                                   notes: notes)
        record.videoURL = destination

        var warnings = outcome.segmentation.warnings + outcome.extraWarnings
        if case .analysableNotComparable(let reasons) = check.verdict {
            warnings.append(contentsOf: reasons)
        }
        warnings.append(contentsOf: check.notes)

        let analysis = SessionAnalysis(
            events: outcome.events.map(EventSnapshot.init),
            phases: outcome.segmentation.phases.map(PhaseSnapshot.init),
            segmentationConfidence: outcome.segmentation.overallConfidence,
            warnings: warnings,
            frameCount: clip.frameCount,
            measuredFrameRate: clip.measuredFrameRate,
            analysisStartTime: outcome.analysisStartTime)

        let session = StoredSession(record: record,
                                    analysis: analysis,
                                    retention: .temporary(
                                        expiresAt: RetentionPolicy.expiryDate()),
                                    videoFilename: filename,
                                    trialNumber: trialNumber)

        try await sessionStore.save(session)
        try await sessionStore.savePoseArchive(poseFrames, for: id)
        try? await profileStore.recordUse(id: profile.id)

        progress(AnalysisProgress(stage: "Done", fraction: 1))
        return session
    }

    // MARK: - Re-analysis

    public func reanalyse(sessionID: UUID,
                          events: [EventSnapshot]) async throws -> ReanalysisOutcome {

        let session = try await sessionStore.load(id: sessionID)

        guard let poseFrames = try? await sessionStore.loadPoseArchive(for: sessionID),
              !poseFrames.isEmpty else {
            throw AnalysisError.poseArchiveMissing(sessionID)
        }

        let profileID = session.record.key.calibrationProfileID
        guard let profile = try? await profileStore.load(id: profileID) else {
            throw AnalysisError.profileMissing(profileID)
        }

        let outcome = try runPipeline(poseFrames: poseFrames,
                                      profile: profile,
                                      deliveredFrameRate: session.analysis.measuredFrameRate,
                                      events: events)

        return ReanalysisOutcome(segmentation: outcome.segmentation,
                                 metricValues: outcome.metricValues,
                                 metricConfidences: outcome.metricConfidences)
    }

    // MARK: - Shared pipeline

    private struct PipelineOutcome {
        var events: [GroundEvent]
        var segmentation: PhaseSegmentation
        var metricValues: [String: Double]
        var metricConfidences: [String: Double]
        var extraWarnings: [String]
        /// Timestamp of the first sample on the analysis grid, needed to
        /// convert between grid indices and video time in the correction UI.
        var analysisStartTime: Double
    }

    /// Reconstruct, then either detect events or adopt the ones supplied.
    ///
    /// `events == nil` means a first analysis: detect them. A non-nil array
    /// means a human has already decided, and detection is skipped entirely.
    ///
    /// `deliveredFrameRate` sets the analysis grid for this run before
    /// anything downstream touches it — `Reconstructor`'s resampling and
    /// `EventDetector`'s filters both read `ProcessingTimebase.analysisRate`
    /// live, so this one call is what makes every stage agree on the same
    /// rate. It must happen first. A first analysis and a re-analysis of the
    /// same session must configure it identically — both pass the session's
    /// own `measuredFrameRate`, never a value recomputed from anything else
    /// — or a re-analysis after an events correction would silently shift
    /// the grid under events a human already confirmed against the original
    /// one.
    private func runPipeline(poseFrames: [PoseFrame],
                             profile: CalibrationProfile,
                             deliveredFrameRate: Double,
                             events: [EventSnapshot]?) throws -> PipelineOutcome {

        ProcessingTimebase.configure(forDeliveredRate: deliveredFrameRate)

        let reconstructor = Reconstructor(model: profile.cameraModel)
        let reconstruction = reconstructor.reconstruct(poseFrames: poseFrames)

        let groundEvents: [GroundEvent]
        if let events {
            groundEvents = events
                .map(\.groundEvent)
                .sorted { $0.timestamp < $1.timestamp }
        } else {
            groundEvents = EventDetector().detectEvents(frames: reconstruction.frames)
        }

        let segmentation = PhaseSegmenter().segment(
            events: groundEvents,
            frames: reconstruction.frames,
            boardScratchLineX: WorldFrame.scratchLineX)

        let metrics = MetricsEngine().measure(frames: reconstruction.frames,
                                              segmentation: segmentation)

        return PipelineOutcome(events: groundEvents,
                               segmentation: segmentation,
                               metricValues: metrics.values,
                               metricConfidences: metrics.confidences,
                               extraWarnings: reconstruction.warnings + metrics.warnings,
                               analysisStartTime: reconstruction.frames.first?.timestamp ?? 0)
    }
}

// MARK: - Pose archive

public extension SessionStore {

    /// 2D pose is archived separately from both the video and the analysis.
    ///
    /// It sits between the two in every dimension: a few hundred kilobytes
    /// against the video's hundreds of megabytes, and it is what makes
    /// re-analysis possible after the footage has been dropped. Without it, a
    /// user who confirmed events on day four would have nothing to re-measure
    /// from.
    func savePoseArchive(_ frames: [PoseFrame], for id: UUID) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(frames)
        try data.write(to: poseArchiveURL(for: id), options: .atomic)
    }

    func loadPoseArchive(for id: UUID) throws -> [PoseFrame] {
        let data = try Data(contentsOf: poseArchiveURL(for: id))
        return try JSONDecoder().decode([PoseFrame].self, from: data)
    }

    func hasPoseArchive(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: poseArchiveURL(for: id).path)
    }
}
