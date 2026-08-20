import Foundation
import AVFoundation
import CoreVideo

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

public enum PoseEstimationError: Error, LocalizedError {
    case modelMissing
    case videoUnreadable(String)
    case frameworkUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "The pose model file is missing from the app bundle. Add "
                 + "pose_landmarker_heavy.task to the app target with Target "
                 + "Membership ticked."
        case .videoUnreadable(let detail):
            return "The recording could not be read: \(detail)"
        case .frameworkUnavailable:
            return "MediaPipe is not linked into this build. Add the "
                 + "MediaPipeTasksVision pod and rebuild."
        }
    }
}

/// Reads every frame of a clip and hands it to a per-frame handler.
///
/// Separated from the pose model so the frame-walking logic — which is where
/// timestamp handling goes wrong — can be tested without MediaPipe present.
/// The timestamps taken here are the sample buffers' own presentation times,
/// not `frameIndex / nominalFrameRate`: a "240 fps" file is never exactly
/// 240 fps, and deriving time from the index would accumulate drift across
/// the clip that lands squarely on the contact timings.
struct VideoFrameReader {

    let url: URL

    func readFrames(_ handle: (CVPixelBuffer, Double, Int) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseEstimationError.videoUnreadable("no video track")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PoseEstimationError.videoUnreadable("reader rejected output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw PoseEstimationError.videoUnreadable(
                reader.error?.localizedDescription ?? "unknown")
        }

        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try handle(buffer, time, index)
            index += 1
        }

        if reader.status == .failed {
            throw PoseEstimationError.videoUnreadable(
                reader.error?.localizedDescription ?? "read failed")
        }
    }

    /// Total frames, for progress reporting.
    func frameCount() async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return 0
        }
        let duration = try await asset.load(.duration).seconds
        let rate = Double(try await track.load(.nominalFrameRate))
        return max(Int((duration * rate).rounded()), 1)
    }
}

#if canImport(MediaPipeTasksVision)

/// MediaPipe-backed pose extraction.
///
/// Runs in `.video` mode rather than `.liveStream`: analysis happens after
/// capture, so there is no real-time constraint and video mode's temporal
/// smoothing across frames gives visibly steadier landmarks than treating
/// each frame independently.
///
/// The heavy model is used deliberately. Inference speed is irrelevant here —
/// the whole clip is processed once, offline — while landmark accuracy during
/// fast motion directly limits every downstream measurement.
public struct PoseEstimator: PoseExtracting {

    private let modelPath: String

    public init() throws {
        guard let path = Bundle.main.path(forResource: PoseModelBundle.filename,
                                          ofType: "task") else {
            throw PoseEstimationError.modelMissing
        }
        modelPath = path
    }

    public func extractPose(from url: URL,
                            progress: @Sendable (Double) -> Void) async throws
        -> [PoseFrame] {

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video
        options.numPoses = 1
        // Detection confidence is left low and filtering is done downstream
        // instead. A landmark suppressed here vanishes without trace; one
        // that arrives with a low score can be weighted, gap-filled, and
        // counted against the frame's `analysisConfidence`, which is what
        // `ConsistencyGuard` gates on.
        options.minPoseDetectionConfidence = 0.3
        options.minPosePresenceConfidence = 0.3
        options.minTrackingConfidence = 0.3

        let landmarker = try PoseLandmarker(options: options)
        let reader = VideoFrameReader(url: url)
        let total = try await reader.frameCount()

        var frames = [PoseFrame]()
        frames.reserveCapacity(total)

        try await reader.readFrames { buffer, timestamp, index in
            let image = try MPImage(pixelBuffer: buffer)
            // MediaPipe wants monotonically increasing integer milliseconds.
            // Derived from the real presentation time, so a dropped source
            // frame produces a gap here too rather than being papered over.
            let milliseconds = Int(timestamp * 1000)
            guard let result = try? landmarker.detect(videoFrame: image,
                                                      timestampInMilliseconds: milliseconds),
                  let landmarks = result.landmarks.first else {
                return
            }

            let width = Double(CVPixelBufferGetWidth(buffer))
            let height = Double(CVPixelBufferGetHeight(buffer))

            var keypoints = [PoseLandmark: Keypoint2D]()
            for (rawIndex, landmark) in landmarks.enumerated() {
                guard let key = PoseLandmark(rawValue: rawIndex) else { continue }
                // MediaPipe emits normalised coordinates; everything
                // downstream works in pixels.
                keypoints[key] = Keypoint2D(
                    position: SIMD2(Double(landmark.x) * width,
                                    Double(landmark.y) * height),
                    confidence: Double(landmark.visibility?.floatValue ?? 1),
                    visibility: Double(landmark.presence?.floatValue ?? 1))
            }

            frames.append(PoseFrame(timestamp: timestamp,
                                    frameIndex: index,
                                    keypoints: keypoints))

            if total > 0 { progress(Double(index) / Double(total)) }
        }

        progress(1)
        return frames
    }
}

#else

/// Stand-in used until the MediaPipe pod is added.
///
/// Throws rather than returning empty frames. An empty result would flow all
/// the way through reconstruction and segmentation and surface as "no ground
/// contacts found", which points the user at their recording technique when
/// the actual problem is a missing dependency.
public struct PoseEstimator: PoseExtracting {

    public init() throws {}

    public func extractPose(from url: URL,
                            progress: @Sendable (Double) -> Void) async throws
        -> [PoseFrame] {
        throw PoseEstimationError.frameworkUnavailable
    }
}

#endif

/// Replays a pose archive as though it had just been extracted.
///
/// Lets the whole analysis path — reconstruction, detection, segmentation,
/// metrics, and the correction screen on top of them — be developed and
/// tested with no camera and no MediaPipe.
public struct ArchivedPoseExtractor: PoseExtracting {

    public let frames: [PoseFrame]

    public init(frames: [PoseFrame]) {
        self.frames = frames
    }

    public func extractPose(from url: URL,
                            progress: @Sendable (Double) -> Void) async throws
        -> [PoseFrame] {
        progress(1)
        return frames
    }
}
