import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// Device, resolution and frame rate a recording was made in.
///
/// The fingerprint is the join key between a lens calibration and a session.
/// `ConsistencyGuard` refuses to analyse a recording whose fingerprint does
/// not match its calibration profile, because high-frame-rate modes crop the
/// sensor: 1080p at 240 fps and 1080p at 120 fps are two different crops of
/// the sensor on most iPhones, so they have materially different effective
/// focal lengths, and applying one calibration to the other is a silent
/// multi-percent scale error on every distance the app reports.
public struct CaptureConfiguration: Codable, Equatable, Sendable {

    public var deviceModel: String
    public var width: Int
    public var height: Int
    public var frameRate: Double

    public init(deviceModel: String, width: Int, height: Int, frameRate: Double) {
        self.deviceModel = deviceModel
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// Stable string form. Frame rate is rounded to a whole number so that a
    /// nominal 240 fps mode delivering 238.9 still matches its calibration —
    /// the crop factor is a property of the mode, not of the delivered rate.
    public var fingerprint: String {
        "\(deviceModel)|\(width)x\(height)|\(Int(frameRate.rounded()))"
    }

    public var displayName: String {
        "\(height)p · \(Int(frameRate.rounded())) fps"
    }

    /// Recover a configuration from its fingerprint.
    ///
    /// Kept next to `fingerprint` so the two halves of the format can never
    /// drift apart. Callers that only need the pixel dimensions — the
    /// skeleton overlay, which must map landmark pixels into view
    /// coordinates — go through here rather than splitting the string
    /// themselves.
    public static func parse(fingerprint: String) -> CaptureConfiguration? {
        let parts = fingerprint.split(separator: "|")
        guard parts.count == 3 else { return nil }
        let dimensions = parts[1].split(separator: "x")
        guard dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1]),
              let rate = Double(parts[2]) else { return nil }
        return CaptureConfiguration(deviceModel: String(parts[0]),
                                    width: width,
                                    height: height,
                                    frameRate: rate)
    }

    public static func imageSize(fromFingerprint fingerprint: String) -> CGSize {
        guard let configuration = parse(fingerprint: fingerprint) else {
            // 1080p is the overwhelmingly common case and a wrong guess only
            // misplaces the overlay, never a measurement.
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(width: configuration.width, height: configuration.height)
    }

    public static var currentDeviceModel: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self,
                                 capacity: MemoryLayout.size(ofValue: $0)) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
        return identifier
    }
}

/// What the camera is being configured for.
public enum CaptureMode: Sendable {
    /// Checkerboard capture. Frame rate does not matter — the board is static
    /// — but the format must be the one that will later be recorded in, or
    /// the intrinsics will not apply to the footage.
    case intrinsicCalibration
    /// Live view for tapping board corners. Single frames only.
    case tripodCalibration
    /// The real thing: pinned high frame rate, locked optics.
    case recording
}

public enum CaptureControllerError: Error, LocalizedError {
    case permissionDenied
    case noCamera
    case noFormatSupporting(frameRate: Double)
    case configurationFailed(String)
    case stabilisationCouldNotBeDisabled
    case notRecording
    case insufficientStorage(requiredMB: Int)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access is off for this app. Turn it on in Settings › "
                 + "Privacy & Security › Camera."
        case .noCamera:
            return "No rear camera was found on this device."
        case .noFormatSupporting(let rate):
            return "This device has no capture format that sustains "
                 + "\(Int(rate)) fps at a usable resolution."
        case .configurationFailed(let detail):
            return "The camera could not be configured: \(detail)"
        case .stabilisationCouldNotBeDisabled:
            return "Video stabilisation could not be turned off on this device. "
                 + "Stabilisation warps the image geometry frame by frame, which "
                 + "breaks the fixed camera-to-world mapping every measurement "
                 + "depends on. Recording would produce plausible but wrong numbers."
        case .notRecording:
            return "No recording is in progress."
        case .insufficientStorage(let mb):
            return "About \(mb) MB of free space is needed for a recording at this "
                 + "frame rate. Free some space and try again."
        }
    }
}

/// Mutable state of one recording, confined to the buffer queue.
///
/// A separate class rather than properties on the controller because the
/// sample-buffer delegate runs on a background queue at up to 240 Hz while
/// the UI reads the controller from the main actor. Mixing the two on one object
/// gives both a data race and — since the controller is `@Observable` —
/// SwiftUI invalidations raised off the main thread. Everything the delegate
/// touches lives here, behind one lock, and nothing here is observable.
private final class RecordingSession {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let url: URL
    var started = false
    var deliveredFrameCount = 0
    var firstPresentationTime: CMTime?
    var lastPresentationTime: CMTime?
    var failure: String?

    init(writer: AVAssetWriter, input: AVAssetWriterInput, url: URL) {
        self.writer = writer
        self.input = input
        self.url = url
    }
}

/// Owns the `AVCaptureSession`.
///
/// Single owner for all camera access in the app. Calibration and recording
/// share it rather than each building their own session, because the format
/// selected during lens calibration *is* the contract for later recording —
/// two independent sessions would make it possible to calibrate in one mode
/// and record in another without anything noticing.
@Observable
public final class CaptureController: NSObject, @unchecked Sendable {

    public let session = AVCaptureSession()

    // Observable surface. Written from the main actor only.
    public private(set) var configuration: CaptureConfiguration?
    public private(set) var isRecording = false
    public private(set) var lastError: String?

    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "capture.session")
    @ObservationIgnored private let bufferQueue = DispatchQueue(label: "capture.buffers")

    /// Guards everything the sample-buffer delegate touches.
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private var recording: RecordingSession?
    @ObservationIgnored private var pendingFrameRequest: ((CVPixelBuffer) -> Void)?

    public override init() {
        super.init()
    }

    // MARK: Permission

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: Configuration

    /// The hardware mode actually selected — which of
    /// `CaptureRequirements.preferredModes` this device supports and is
    /// currently configured for. `nil` before the first `configure` call.
    public private(set) var selectedMode: CaptureRequirements.HardwareMode?

    /// Configure the session for a mode.
    ///
    /// Throws rather than degrading. A session that silently fell back to
    /// 60 fps still records perfectly good-looking video, and the resulting
    /// contact times would be wrong by tens of milliseconds with nothing on
    /// screen to say so.
    ///
    /// An optional explicit mode overrides the automatic ranked selection —
    /// this is what lets a user deliberately choose 1080p120 in `Settings`
    /// for better low-light sensitivity, trading it for coarser timing.
    /// Without an override, the highest-preference mode this device
    /// supports is selected, and — critically — the *same* mode every time
    /// on a given device: the selection depends only on what the hardware
    /// offers, never on ambient light, so a lens calibration measured today
    /// stays valid for a recording made next month on the same phone.
    @discardableResult
    /// - Parameter lensPosition: The focus position this session's calibration
    ///   was measured at, from `CameraIntrinsics.lensPosition`. Applied only
    ///   for `.recording`. Passing `nil` locks focus wherever the lens
    ///   currently sits, which is correct only for a profile calibrated
    ///   before focus position was recorded.
    public func configure(mode: CaptureMode,
                          preferring override: CaptureRequirements.HardwareMode? = nil,
                          lensPosition: Float? = nil)
        throws -> CaptureConfiguration {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CaptureControllerError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            throw CaptureControllerError.noCamera
        }
        self.device = device

        // Calibration and recording resolve to the same mode deliberately.
        // The intrinsics only apply to the mode they were measured in, so
        // the tripod-tapping view running at a different resolution or rate
        // would produce a profile that cannot legally be used for the
        // eventual recording.
        guard let (selected, format) = Self.resolveMode(for: device, preferring: override)
        else {
            throw CaptureControllerError.noFormatSupporting(
                frameRate: override?.frameRate
                    ?? CaptureRequirements.preferredModes.last?.frameRate ?? 120)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .inputPriority

        if let existing = videoInput {
            session.removeInput(existing)
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureControllerError.configurationFailed("input rejected")
        }
        session.addInput(input)
        videoInput = input

        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            // Dropping late frames would silently punch holes in the very
            // signal being measured. Better to stall than to lose a frame at
            // touchdown.
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.setSampleBufferDelegate(self, queue: bufferQueue)
            guard session.canAddOutput(videoOutput) else {
                throw CaptureControllerError.configurationFailed("output rejected")
            }
            session.addOutput(videoOutput)
        }

        try device.lockForConfiguration()
        device.activeFormat = format

        if CaptureRequirements.pinFrameDuration {
            // Both ends. Setting only the minimum leaves iOS free to slow
            // down when it wants a longer exposure, which is precisely the
            // failure this pinning exists to prevent.
            let duration = CMTime(value: 1, timescale: CMTimeScale(selected.frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }

        switch mode {
        case .recording:
            try lockOptics(on: device, lensPosition: lensPosition)
        case .intrinsicCalibration, .tripodCalibration:
            // Calibration must share the recording *format* — the crop factor
            // is what the fingerprint protects — but it must not inherit the
            // recording *optics*. Locking focus here was freezing the lens
            // wherever it happened to sit, so a checkerboard held in front of
            // the phone could never be brought into focus, and the 1/500 s
            // exposure left the board too dark to detect indoors.
            try openOptics(on: device)
        }
        device.unlockForConfiguration()

        try disableStabilisation()

        let configuration = CaptureConfiguration(
            deviceModel: CaptureConfiguration.currentDeviceModel,
            width: selected.width,
            height: selected.height,
            frameRate: selected.frameRate)
        self.configuration = configuration
        self.selectedMode = selected
        return configuration
    }

    /// Walk the ranked mode list and return the first this device supports,
    /// together with the matching format.
    ///
    /// Exact resolution match rather than "largest available at this rate".
    /// The old selection picked whichever format had the most pixels at the
    /// target rate, which on a device offering, say, 4K at 240 fps in some
    /// future hardware generation would silently select a mode never listed
    /// in `preferredModes` and never validated. Matching against the named
    /// modes keeps the set of things this app will ever record in closed
    /// and known.
    static func resolveMode(for device: AVCaptureDevice,
                            preferring override: CaptureRequirements.HardwareMode?)
        -> (CaptureRequirements.HardwareMode, AVCaptureDevice.Format)? {

        let candidates = override.map { [$0] } ?? CaptureRequirements.preferredModes
        for candidate in candidates {
            if let format = matchingFormat(for: device, mode: candidate) {
                return (candidate, format)
            }
        }
        return nil
    }

    private static func matchingFormat(
        for device: AVCaptureDevice,
        mode: CaptureRequirements.HardwareMode) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) == mode.width,
                  Int(dimensions.height) == mode.height else { return false }
            // Binned formats trade resolution for sensitivity by merging
            // pixels. That changes the effective focal length in a way the
            // calibration would have to match exactly, so they are excluded
            // rather than reasoned about.
            guard !format.isVideoBinned else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= mode.frameRate && mode.frameRate <= $0.maxFrameRate
            }
        }
    }

    /// Which of the ranked modes this device supports, for the settings and
    /// hardware-check screens. Evaluated fresh each call rather than cached,
    /// since it is only ever called from a handful of diagnostic screens.
    public static func supportedModes() -> [CaptureRequirements.HardwareMode] {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else { return [] }
        return CaptureRequirements.preferredModes.filter {
            matchingFormat(for: device, mode: $0) != nil
        }
    }

    /// Hand focus and exposure back to the camera, for the calibration modes.
    ///
    /// The board is static, so none of the reasons recording locks the optics
    /// apply: there is no motion to smear, and no approach run during which a
    /// refocus could change the focal length mid-measurement. What matters
    /// here is simply that the user can see the board and the detector can
    /// find its corners.
    ///
    /// Focus is *not* left roaming for the whole session, though — see
    /// `focusAndLock`. It roams until the board is sharp, then it is pinned,
    /// and every captured view uses that one pinned position.
    private func openOptics(on device: AVCaptureDevice) throws {
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func lockOptics(on device: AVCaptureDevice,
                            lensPosition: Float? = nil) throws {
        // Exposure capped well under the frame budget. At the tightest
        // supported mode, 240 fps, the budget is 4.2 ms; anything
        // approaching it smears the foot across the frames either side of
        // touchdown, which is exactly where the contact boundary is
        // measured from.
        let cap = CMTime(seconds: CaptureRequirements.maximumExposureSeconds,
                         preferredTimescale: 1_000_000)
        if device.isExposureModeSupported(.custom) {
            let iso = min(max(device.activeFormat.minISO * 4,
                              device.activeFormat.minISO),
                          device.activeFormat.maxISO)
            device.setExposureModeCustom(duration: cap, iso: iso)
        } else if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }

        // Focus locked: a refocus mid-approach changes the effective focal
        // length, and the whole measurement chain is scaled by that number.
        //
        // Restored to the *calibrated* position where one is known, rather
        // than frozen wherever the lens happens to be. Focal length varies
        // with focus, so intrinsics measured at one lens position do not
        // describe footage shot at another — a scale error of exactly the
        // kind the mode fingerprint exists to catch, but one the fingerprint
        // cannot see, because resolution and frame rate are identical either
        // way.
        if let lensPosition,
           device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(
                lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
        } else if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
    }

    /// Where the lens is sitting right now, `0` near to `1` far.
    public var currentLensPosition: Float? { device?.lensPosition }

    /// Open up focus and exposure without touching the resolved format.
    ///
    /// For screens that share the already-configured session rather than
    /// configuring it themselves — tripod calibration, which must tap points
    /// on exactly the format the intrinsics were measured in and so must not
    /// risk re-resolving the mode. Calling `configure(mode: .tripodCalibration)`
    /// there would re-run mode selection without the user's manual override
    /// in hand, and could quietly land on a different resolution than the
    /// profile is keyed to.
    public func openOpticsForCalibration() throws {
        guard let device else { throw CaptureControllerError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        try openOptics(on: device)
    }

    /// Hand focus back to the camera after `focusAndLock`.
    ///
    /// Only meaningful in the calibration modes. Anything captured at the
    /// previous focus position describes a different focal length and must be
    /// discarded by the caller, not merged with what follows.
    public func unlockFocus() throws {
        guard let device else { throw CaptureControllerError.noCamera }
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return }
        try device.lockForConfiguration()
        device.focusMode = .continuousAutoFocus
        device.unlockForConfiguration()
    }

    /// Focus on whatever the camera is pointed at, then pin the lens there
    /// and report where it ended up.
    ///
    /// This is the moment the calibration's focal length is decided. Every
    /// view captured afterwards must be taken at this same lens position, and
    /// so must the recording — which is why the returned value is stored in
    /// `CameraIntrinsics.lensPosition` and handed back to
    /// `configure(mode:preferring:lensPosition:)` at record time.
    ///
    /// Point the phone at something at roughly the distance the athlete will
    /// be before calling this. A lens pinned for a board held at arm's length
    /// will render a runway six metres away soft, and soft footage costs
    /// landmark precision at exactly the foot-ground boundary the whole
    /// measurement rests on.
    @discardableResult
    public func focusAndLock(timeout: Duration = .seconds(3)) async throws -> Float {
        guard let device else { throw CaptureControllerError.noCamera }

        if device.isFocusModeSupported(.autoFocus) {
            try device.lockForConfiguration()
            device.focusMode = .autoFocus
            device.unlockForConfiguration()

            // Polled rather than observed: this runs once, on a user tap, and
            // a KVO observer here would outlive the call and need tearing
            // down on every path out of the calibration screen.
            //
            // Two phases, because `isAdjustingFocus` does not become true the
            // instant the mode is set. Waiting only for it to go false would
            // usually see "false" immediately — before the sweep began — and
            // pin the lens exactly where it was, which is the bug this whole
            // method exists to fix, reintroduced one layer down.
            let deadline = ContinuousClock.now + timeout
            while !device.isAdjustingFocus && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            while device.isAdjustingFocus && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let settled = device.lensPosition
        try device.lockForConfiguration()
        if device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: settled, completionHandler: nil)
        } else if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        device.unlockForConfiguration()
        return settled
    }

    /// Turn stabilisation off and verify it took.
    ///
    /// The most damaging default on the platform for this application.
    /// Stabilisation warps image geometry per frame to smooth motion, which
    /// breaks the fixed camera-to-world mapping every distance depends on. On
    /// some devices the setter is accepted and ignored, so the result is
    /// checked rather than assumed.
    private func disableStabilisation() throws {
        guard let connection = videoOutput.connection(with: .video) else { return }
        guard connection.isVideoStabilizationSupported else { return }
        connection.preferredVideoStabilizationMode =
            CaptureRequirements.videoStabilisationMode
        if connection.activeVideoStabilizationMode != .off {
            throw CaptureControllerError.stabilisationCouldNotBeDisabled
        }
    }

    // MARK: Running

    public func startRunning() {
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    public func stopRunning() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    // MARK: Single frames, for calibration

    /// Hand the next arriving frame to `handler`.
    public func captureFrame(_ handler: @escaping (CVPixelBuffer) -> Void) {
        stateLock.lock()
        pendingFrameRequest = handler
        stateLock.unlock()
    }

    /// The next frame as a `GrayImage`, for checkerboard detection.
    ///
    /// Times out rather than hanging. If the session is not running — a
    /// backgrounded app, a revoked permission — the continuation would
    /// otherwise never resume and the calibration screen would sit on a
    /// spinner with no way forward.
    public func nextGrayImage(downsample: Int = 1,
                              timeout: Duration = .seconds(2)) async -> GrayImage? {
        let image: GrayImage? = await withTaskGroup(of: GrayImage?.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { continuation in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.captureFrame { buffer in
                        continuation.resume(
                            returning: GrayImage.from(pixelBuffer: buffer,
                                                      downsample: downsample))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return image
    }

    // MARK: Recording

    public func startRecording(to url: URL) throws {
        guard let configuration else {
            throw CaptureControllerError.configurationFailed("not configured")
        }
        try Self.checkStorage(forSeconds: 15, configuration: configuration)

        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                // Generous bitrate. Compression artefacts at the foot-ground
                // boundary are indistinguishable from real motion to the pose
                // model, and that boundary is the measurement.
                AVVideoAverageBitRateKey: configuration.width
                    * configuration.height * 12,
                AVVideoExpectedSourceFrameRateKey: Int(configuration.frameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(configuration.frameRate),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureControllerError.configurationFailed("writer input rejected")
        }
        writer.add(input)

        stateLock.lock()
        recording = RecordingSession(writer: writer, input: input, url: url)
        stateLock.unlock()

        isRecording = true
        lastError = nil
    }

    /// Stop and report what was actually written.
    public func stopRecording() async throws -> CapturedClip {
        stateLock.lock()
        let session = recording
        recording = nil
        stateLock.unlock()

        guard isRecording, let session else {
            throw CaptureControllerError.notRecording
        }
        isRecording = false

        session.input.markAsFinished()
        await session.writer.finishWriting()

        if let failure = session.failure {
            throw CaptureControllerError.configurationFailed(failure)
        }
        guard let first = session.firstPresentationTime,
              let last = session.lastPresentationTime,
              session.deliveredFrameCount > 1 else {
            throw CaptureControllerError.configurationFailed("no frames were recorded")
        }

        let span = (last - first).seconds
        // Measured, not requested. The gap between the two is the whole
        // reason this is computed here rather than read off the format.
        let measuredRate = span > 0
            ? Double(session.deliveredFrameCount - 1) / span : 0

        return CapturedClip(url: session.url,
                            measuredFrameRate: measuredRate,
                            frameCount: session.deliveredFrameCount,
                            duration: span,
                            captureFingerprint: configuration?.fingerprint ?? "unknown",
                            // Read now, at the end of the recording, so a lock
                            // that was refused or silently reset shows up as
                            // the value it really held rather than the one it
                            // was asked for.
                            lensPosition: device.map { Double($0.lensPosition) })
    }

    /// Rough free-space gate before arming.
    ///
    /// A jump lost to a full disk is a jump the athlete has to repeat, which
    /// in a competition warm-up may not be possible.
    static func checkStorage(forSeconds seconds: Double,
                             configuration: CaptureConfiguration) throws {
        let bytesPerSecond = Double(configuration.width * configuration.height * 12) / 8
        let required = Int(bytesPerSecond * seconds)
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? .max
        guard available > Int64(required) else {
            throw CaptureControllerError.insufficientStorage(
                requiredMB: required / 1_000_000)
        }
    }

    /// Thermal state, surfaced so the capture screen can warn before a
    /// recording rather than after one. Sustained 240 fps capture heats a
    /// phone quickly, and a throttled device drops frames.
    public var thermalWarning: String? {
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            return "The phone is running hot. Frame rate may drop below what "
                 + "analysis needs. Let it cool for a few minutes."
        case .critical:
            return "The phone is too hot to record reliably. Recording now will "
                 + "almost certainly drop frames."
        default:
            return nil
        }
    }
}

// MARK: - Buffer delegate

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Called on `bufferQueue` at the capture rate.
    ///
    /// Nothing observable is touched here. Every mutation goes through
    /// `stateLock` onto `RecordingSession`, and the one piece of UI state
    /// this path can produce — a writer failure — is stashed there and
    /// surfaced by `stopRecording` on the main actor.
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {

        stateLock.lock()
        let request = pendingFrameRequest
        if request != nil { pendingFrameRequest = nil }
        let session = recording
        stateLock.unlock()

        if let request, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            request(buffer)
        }

        guard let session else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        stateLock.lock()
        defer { stateLock.unlock() }

        if !session.started {
            guard session.writer.startWriting() else {
                session.failure = session.writer.error?.localizedDescription
                    ?? "writer refused to start"
                return
            }
            session.writer.startSession(atSourceTime: presentationTime)
            session.started = true
            session.firstPresentationTime = presentationTime
        }

        guard session.input.isReadyForMoreMediaData else { return }
        if session.input.append(sampleBuffer) {
            session.deliveredFrameCount += 1
            session.lastPresentationTime = presentationTime
        }
    }
}
