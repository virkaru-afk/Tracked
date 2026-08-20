import Foundation
import AVFoundation
import CoreMedia

// =====================================================================
// HARDWARE BOUNDARY — iPhone camera
//
// This file is the seam between the analysis pipeline, which is written
// and validated, and the device, which is not yet wired up. Everything
// below is either a protocol the rest of the app already codes against
// or a stub marked UNIMPLEMENTED with a note on what it must do.
//
// What already exists elsewhere in the package:
//   • CaptureConfiguration — carries the device/resolution/frame-rate
//     fingerprint. Referenced by ConsistencyGuard and CameraIntrinsics.
//   • CaptureController   — configures the AVCaptureSession and pins the
//     frame duration. SETUP.md lists it as complete; its source is not in
//     this directory.
//   • PoseEstimator       — wrapped in #if canImport(MediaPipeTasksVision),
//     so it compiles away until the pod is added.
//
// What this file adds: the recording-to-session seam, which nothing owns
// yet, and an explicit statement of the device work still outstanding.
// =====================================================================

// MARK: - Capture requirements

/// The capture format this tool requires, and why each part is required.
///
/// These are not preferences. Each one, if missed, invalidates measurements
/// in a way that is invisible in the resulting video.
public enum CaptureRequirements {

    /// One resolution/rate combination the iPhone can actually deliver.
    ///
    /// This app previously targeted a flat "150 fps", which no iPhone camera
    /// has ever offered — slow-motion capture on iOS is quantised to fixed
    /// modes, not a continuously requestable rate. The real modes, in every
    /// generation that supports high-frame-rate video, are these three.
    // `Hashable` rather than just `Equatable` because SwiftUI's `Picker`
    // requires it of anything used as a `.tag`, and the settings screen offers
    // the supported modes as a list. Every stored property is already
    // hashable, so the conformance synthesises.
    public struct HardwareMode: Sendable, Hashable {
        public let width: Int
        public let height: Int
        public let frameRate: Double
        public let label: String

        public var fingerprint: String { "\(width)x\(height)@\(Int(frameRate))" }
    }

    /// Every mode this app will select, in preference order.
    ///
    /// Ranked by what actually buys accuracy, most valuable first:
    ///
    /// 1. **1080p at 240 fps** — the frame budget is 4.2 ms, tightening
    ///    every contact-time and event-boundary measurement over the old
    ///    150 Hz target by more than a third, at full 1080p landmark
    ///    precision. The default whenever the device supports it.
    /// 2. **720p at 240 fps** — same timing precision, fewer pixels across
    ///    the athlete. Falls back to this only when a device's image
    ///    signal processor cannot sustain 1080p at 240 fps, which is a real
    ///    limit on some older hardware.
    /// 3. **1080p at 120 fps** — full resolution, an 8.3 ms frame budget.
    ///    The floor: below this, `ConsistencyGuard` refuses to analyse at
    ///    all, because contact timing degrades past usefulness.
    ///
    /// The list is fixed and evaluated once per device at configure time —
    /// it does not change with lighting. Adapting the *requested* mode to
    /// the conditions would mean two sessions on the same phone could be
    /// recorded in different modes, which breaks the fingerprint match a
    /// stored calibration profile depends on. Instead a fixed mode is
    /// requested every time, and if the phone cannot actually sustain it in
    /// low light, that shows up honestly in the *delivered* rate, which
    /// `DeviceJumpRecorder.stop()` measures and rejects if it falls below
    /// `minimumFrameRate` — a loud failure on the runway rather than a
    /// silent, invisible one in the data.
    public static let preferredModes: [HardwareMode] = [
        HardwareMode(width: 1920, height: 1080, frameRate: 240, label: "1080p240"),
        HardwareMode(width: 1280, height: 720, frameRate: 240, label: "720p240"),
        HardwareMode(width: 1920, height: 1080, frameRate: 120, label: "1080p120"),
    ]

    /// Below this, `ConsistencyGuard` rejects the recording outright: at
    /// 100 fps a 110 ms step contact yields only eleven samples and the
    /// boundary frames dominate the measurement. 120 fps is the floor of
    /// every mode above, so this is never the binding constraint on a
    /// correctly configured device — it exists for the device that reports
    /// a delivered rate below what it was asked for.
    public static let minimumFrameRate: Double = 120

    /// Frame duration must be pinned at both ends, to whichever mode was
    /// selected. iOS treats frame rate as a target rather than a contract
    /// and will silently drop it to hold exposure in dim light; a session
    /// that quietly ran at 90 fps is not comparable to one at 240 and
    /// nothing in the file says so. `AVCaptureDevice.activeVideoMinFrameDuration`
    /// and `activeVideoMaxFrameDuration` must both be set to the selected
    /// mode's rate.
    public static let pinFrameDuration = true

    /// Exposure duration is capped so the sensor cannot buy brightness with
    /// time. At the tightest supported mode — 240 fps — the frame budget is
    /// 4.2 ms; anything approaching it smears the foot across the frames
    /// either side of touchdown, which is exactly where the boundary is
    /// measured from. The cap is set well under even that, so it binds
    /// identically whichever mode is active.
    public static let maximumExposureSeconds: Double = 1.0 / 500

    /// Focus, exposure and white balance must be locked before recording
    /// starts. A refocus mid-approach changes the effective focal length,
    /// and the whole measurement chain is scaled by that number.
    public static let lockOpticalParameters = true

    /// Video stabilisation must be OFF. Stabilisation warps the image
    /// geometry per-frame to smooth motion, which breaks the fixed
    /// camera-to-world mapping that every distance depends on. This is the
    /// single most damaging default on the platform for this application.
    public static let videoStabilisationMode: AVCaptureVideoStabilizationMode = .off
}

// MARK: - Recording seam

/// A finished recording, before analysis.
public struct CapturedClip: Sendable {
    public let url: URL
    /// Frame rate measured from the file, not the rate that was requested.
    /// The request is a hope; the file is the fact, and every downstream
    /// timing figure is scaled by it.
    public let measuredFrameRate: Double
    public let frameCount: Int
    public let duration: Double
    public let captureFingerprint: String

    /// Where the lens actually was while this clip was written, `0` near to
    /// `1` far.
    ///
    /// Read back from the device rather than assumed from what was requested,
    /// for the same reason `measuredFrameRate` is measured rather than taken
    /// from the format: a lock can be refused or reset, and the difference is
    /// invisible in the footage. `ConsistencyGuard` compares it against the
    /// position the calibration was measured at.
    public let lensPosition: Double?

    public init(url: URL,
                measuredFrameRate: Double,
                frameCount: Int,
                duration: Double,
                captureFingerprint: String,
                lensPosition: Double? = nil) {
        self.url = url
        self.measuredFrameRate = measuredFrameRate
        self.frameCount = frameCount
        self.duration = duration
        self.captureFingerprint = captureFingerprint
        self.lensPosition = lensPosition
    }
}

public enum CaptureFailure: Error, LocalizedError {
    case permissionDenied
    case noBackCamera
    case formatUnavailable(requestedFPS: Double)
    case frameRateNotSustained(requested: Double, delivered: Double)
    case writeFailed(underlying: String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access is off for this app. Turn it on in Settings › "
                 + "Privacy & Security › Camera."
        case .noBackCamera:
            return "No rear camera was found on this device."
        case .formatUnavailable(let fps):
            return "This device has no capture format that sustains \(Int(fps)) fps "
                 + "at a usable resolution."
        case .frameRateNotSustained(let requested, let delivered):
            return "Recording asked for \(Int(requested)) fps but the file came back "
                 + "at \(Int(delivered)) fps. This is almost always light: the sensor "
                 + "lengthens exposure to compensate and drops frames to afford it."
        case .writeFailed(let underlying):
            return "The recording could not be written: \(underlying)"
        case .notImplemented(let what):
            return "\(what) is not implemented yet."
        }
    }
}

/// What the session layer needs from the camera.
///
/// The rest of the app depends on this protocol, never on AVFoundation
/// directly, so the record-analyse-review flow can be exercised in the
/// simulator against a canned clip while the device path is being built.
public protocol JumpRecording: Sendable {
    /// Prepare the session and pin the format. Throws rather than degrading:
    /// a silently reduced frame rate is worse than a refusal.
    func prepare() async throws

    /// Record until `stop()`, writing to `destination`.
    func start(writingTo destination: URL) async throws

    /// Stop and return the measured properties of what was actually written.
    func stop() async throws -> CapturedClip

    /// Live preview layer for the viewfinder.
    var previewSession: AVCaptureSession? { get }
}

// MARK: - Device implementation (OUTLINE)

/// Real-hardware implementation.
///
/// UNIMPLEMENTED. Every method below states what it must do; none of it has
/// been written, compiled, or run on a device. Nothing in this project has
/// touched hardware yet — the numerical core was validated by porting the
/// algorithms to Python and testing them against synthetic trials with known
/// ground truth.
///
/// The work itself lives in `CaptureController`, which owns the app's single
/// `AVCaptureSession`. This type is a thin adapter onto the `JumpRecording`
/// protocol so callers that only want "record me a jump" do not have to know
/// about capture modes or session lifecycle. It deliberately does not build
/// its own session: a second one would make it possible to calibrate in one
/// capture format and record in another, which is exactly the mismatch the
/// fingerprint machinery exists to catch, and it would look like a perfectly
/// good camera preview the whole time.
public final class DeviceJumpRecorder: JumpRecording, @unchecked Sendable {

    private let controller: CaptureController

    /// Focus position from the calibration profile in use, re-applied when
    /// the session is configured so the footage is shot at the focal length
    /// the intrinsics actually describe.
    private let calibratedLensPosition: Float?

    public var previewSession: AVCaptureSession? { controller.session }

    public init(controller: CaptureController,
                calibratedLensPosition: Float? = nil) {
        self.controller = controller
        self.calibratedLensPosition = calibratedLensPosition
    }

    public func prepare() async throws {
        guard await CaptureController.requestPermission() else {
            throw CaptureFailure.permissionDenied
        }
        try controller.configure(mode: .recording,
                                 lensPosition: calibratedLensPosition)
        controller.startRunning()
    }

    public func start(writingTo destination: URL) async throws {
        try controller.startRecording(to: destination)
    }

    public func stop() async throws -> CapturedClip {
        let requestedRate = controller.configuration?.frameRate
            ?? CaptureRequirements.minimumFrameRate
        let clip = try await controller.stopRecording()
        // The delivered rate is measured from sample-buffer timestamps, not
        // read off the requested format. Rejecting here rather than letting
        // ConsistencyGuard catch it later means the user finds out while the
        // athlete is still on the runway.
        guard clip.measuredFrameRate >= CaptureRequirements.minimumFrameRate else {
            throw CaptureFailure.frameRateNotSustained(
                requested: requestedRate,
                delivered: clip.measuredFrameRate)
        }
        return clip
    }
}

/// Plays a bundled clip back as though it had just been recorded.
///
/// Lets the record → analyse → confirm → results flow be built and tested in
/// the simulator, which has no camera. The frame rate is read from the file
/// rather than asserted, so a fixture recorded at the wrong rate fails the
/// same consistency checks a real one would.
public actor FixtureJumpRecorder: JumpRecording {

    public let fixtureURL: URL

    // `nonisolated` because the protocol requirement is synchronous and this
    // type is an actor. Safe here for the reason it would not be on the device
    // recorder: there is no session to hand back and no actor state to read —
    // a fixture has nothing to preview, so this is a constant, not a getter.
    public nonisolated var previewSession: AVCaptureSession? { nil }

    public init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    public func prepare() async throws {}

    public func start(writingTo destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        lastDestination = destination
    }

    private var lastDestination: URL?

    public func stop() async throws -> CapturedClip {
        guard let url = lastDestination else {
            throw CaptureFailure.notImplemented("No fixture recording in progress")
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureFailure.writeFailed(underlying: "fixture has no video track")
        }
        let rate = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        return CapturedClip(url: url,
                            measuredFrameRate: rate,
                            frameCount: Int((rate * duration).rounded()),
                            duration: duration,
                            captureFingerprint: "fixture")
    }
}

// MARK: - Outstanding device work

/// The device-side work, and what remains of it.
///
/// | Area | Where | State |
/// |---|---|---|
/// | Camera permission flow | `CaptureController.requestPermission` | Written |
/// | Format selection matching the calibrated fingerprint | `CaptureController.resolveMode` | Written |
/// | Frame-duration pinning at both ends | `CaptureController.configure` | Written |
/// | Exposure cap, focus/exposure/WB lock | `CaptureController.lockOptics` | Written |
/// | Stabilisation disable, with verification | `CaptureController.disableStabilisation` | Written |
/// | AVAssetWriter path with per-buffer PTS capture | `CaptureController.captureOutput` | Written |
/// | Delivered-frame-rate measurement | `CaptureController.stopRecording` | Written |
/// | Thermal and free-space guards | `CaptureController.thermalWarning`, `.checkStorage` | Written |
/// | MediaPipe pod integration and model bundling | — | Not started |
/// | Pose extraction over a recorded file | `PoseEstimator` | Written, needs the pod |
/// | Any execution on real hardware | — | **Not started** |
///
/// The last row is the one that matters, and none of the rows above it
/// change it. Every accuracy figure quoted in SETUP.md — 2.5 mm hop
/// repeatability, 5.0 ms contact-time SD — comes from synthetic trials. They
/// establish that the algorithms are internally consistent. They do not
/// establish real-world accuracy, and cannot until a session is recorded on a
/// device and measured against a tape.
public enum DeviceIntegrationStatus {
    public static let hasRunOnHardware = false
}
