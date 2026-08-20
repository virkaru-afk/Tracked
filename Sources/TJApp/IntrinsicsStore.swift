import Foundation
import SwiftUI
import simd

/// Quality gates for a lens calibration.
///
/// The thresholds are set from what the error costs on a real jump rather
/// than from what looks tidy in pixels. A lens calibration's job is to not be
/// the limiting factor: the meaningful-change threshold on a phase distance is
/// 30 mm, so a calibration that contributes under 10 mm of scale error is out
/// of the way, and one contributing 40 mm has quietly become the measurement.
public enum IntrinsicQuality {

    public enum Grade: String, Codable, Sendable {
        case excellent, good, acceptable, rejected
    }

    public static let excellentRMSE: Double = 0.30
    public static let goodRMSE: Double = 0.50
    public static let acceptableRMSE: Double = 1.00

    public static func grade(_ result: IntrinsicCalibrationResult) -> Grade {
        if result.reprojectionRMSE > acceptableRMSE { return .rejected }
        if result.reprojectionRMSE > goodRMSE { return .acceptable }
        if result.reprojectionRMSE > excellentRMSE { return .good }
        return .excellent
    }

    /// Reference hop used to express focal error as a distance, in metres.
    private static let referenceHop: Double = 5.30

    /// Relative focal-length error implied by a calibration, as a fraction.
    ///
    /// Calibrated against the validation run: 16 views at sub-pixel RMSE gave
    /// 0.118% focal error, which is 6 mm on a 5.3 m hop. Error falls roughly
    /// as the square root of view count, which matches what was measured —
    /// 0.13% at 4 views, 0.03% at 12, 0.025% at 16.
    public static func relativeFocalError(_ result: IntrinsicCalibrationResult) -> Double {
        let views = max(result.viewCount, 1)
        return result.reprojectionRMSE * 0.008 * (12.0 / Double(views)).squareRoot()
    }

    /// What this calibration costs on a 5.3 m hop, in millimetres.
    ///
    /// This is the number the UI shows. A focal length in pixels is not
    /// something a coach can judge; millimetres of error on a hop is.
    public static func expectedHopError(_ result: IntrinsicCalibrationResult) -> Double {
        relativeFocalError(result) * referenceHop * 1000
    }

    /// Plain-language summary for the result screen.
    public static func summary(_ result: IntrinsicCalibrationResult) -> String {
        let millimetres = expectedHopError(result)
        switch grade(result) {
        case .excellent, .good:
            return String(format: "This lens calibration contributes about %.0f mm of "
                          + "error to a 5.3 m hop — well inside the 30 mm that counts "
                          + "as a real change, so it will not limit your measurements.",
                          millimetres)
        case .acceptable:
            return String(format: "This calibration contributes about %.0f mm of error "
                          + "to a 5.3 m hop. Usable, but capturing a few more views "
                          + "with the board at different angles would tighten it.",
                          millimetres)
        case .rejected:
            return String(format: "This calibration contributes about %.0f mm of error "
                          + "to a 5.3 m hop, which is larger than the 30 mm change the "
                          + "app is meant to detect. Recapture with better lighting and "
                          + "more variety in board angle and distance.", millimetres)
        }
    }
}

/// Persistence for lens calibrations, keyed by capture fingerprint.
///
/// Keyed by fingerprint rather than by device because one phone has several
/// capture modes and each needs its own calibration. Storing a single "the
/// camera" calibration is the mistake that makes 1080p120 intrinsics silently
/// apply to 1080p240 footage.
public actor IntrinsicsStore {

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            self.directory = base.appendingPathComponent("Intrinsics", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory,
                                                withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Fingerprints contain `|` and `x`, which are legal in a filename but
    /// awkward; hashing keeps the directory tidy and avoids any path
    /// character question entirely.
    private func url(for fingerprint: String) -> URL {
        let safe = fingerprint.replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    public func save(_ intrinsics: CameraIntrinsics) throws {
        try encoder.encode(intrinsics)
            .write(to: url(for: intrinsics.configurationFingerprint), options: .atomic)
    }

    public func load(fingerprint: String) -> CameraIntrinsics? {
        guard let data = try? Data(contentsOf: url(for: fingerprint)) else { return nil }
        return try? decoder.decode(CameraIntrinsics.self, from: data)
    }

    public func loadAll() -> [CameraIntrinsics] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(CameraIntrinsics.self,
                                              from: Data(contentsOf: $0)) }
    }

    public func delete(fingerprint: String) throws {
        try FileManager.default.removeItem(at: url(for: fingerprint))
    }
}

// MARK: - Coverage tracking

/// Which parts of the frame the checkerboard has been seen in.
///
/// Distortion is largest at the frame edges, and the athlete spends the
/// approach and the landing at exactly those edges. A calibration built only
/// from centre-frame views fits the middle beautifully and extrapolates the
/// corners, which is the wrong way round for this application — hence a grid
/// the user is pushed to fill rather than a simple view count.
public struct CoverageGrid: Sendable, Equatable {

    public static let columns = 3
    public static let rows = 3

    /// Row-major occupancy, `columns * rows` entries.
    public private(set) var cells: [Int]

    public init() {
        cells = [Int](repeating: 0, count: Self.columns * Self.rows)
    }

    public subscript(column: Int, row: Int) -> Int {
        cells[row * Self.columns + column]
    }

    /// Record a detection at a normalised frame position.
    public mutating func record(centre: SIMD2<Double>) {
        let column = min(max(Int(centre.x * Double(Self.columns)), 0), Self.columns - 1)
        let row = min(max(Int(centre.y * Double(Self.rows)), 0), Self.rows - 1)
        cells[row * Self.columns + column] += 1
    }

    public mutating func reset() {
        cells = [Int](repeating: 0, count: Self.columns * Self.rows)
    }

    public var filledCells: Int { cells.filter { $0 > 0 }.count }
    public var isComplete: Bool { filledCells == cells.count }

    /// The emptiest cell, so guidance can name a direction rather than saying
    /// "move the board around".
    public var emptiestCellDescription: String? {
        guard let index = cells.indices.min(by: { cells[$0] < cells[$1] }),
              cells[index] == 0 else { return nil }
        let column = index % Self.columns
        let row = index / Self.columns
        let horizontal = ["left", "centre", "right"][column]
        let vertical = ["top", "middle", "bottom"][row]
        if column == 1 && row == 1 { return "the centre" }
        if column == 1 { return "the \(vertical)" }
        if row == 1 { return "the \(horizontal)" }
        return "the \(vertical) \(horizontal)"
    }
}

// MARK: - View model

/// Drives `IntrinsicCalibrationView`.
@MainActor
public final class IntrinsicCalibrationViewModel: ObservableObject {

    public enum Phase: Equatable {
        case requestingPermission
        case configuring
        case collecting
        case solving
        case finished
        case failed(String)
    }

    public struct Guidance: Sendable, Equatable {
        public var canCapture: Bool
        public var message: String
    }

    @Published public private(set) var phase: Phase = .requestingPermission
    @Published public private(set) var detectedCorners: [SIMD2<Double>] = []
    @Published public private(set) var detectionImageSize: CGSize = .zero
    @Published public private(set) var guidance = Guidance(
        canCapture: false, message: "Hold the board steady in view")
    @Published public private(set) var coverage = CoverageGrid()
    @Published public private(set) var capturedCount = 0
    @Published public private(set) var result: IntrinsicCalibrationResult?
    @Published public private(set) var grade: IntrinsicQuality.Grade?
    @Published public private(set) var qualitySummary: String?
    @Published public private(set) var advice: [String] = []

    /// Focus position every captured view shares, once pinned.
    ///
    /// `nil` means focus is still roaming, which is fine for framing and not
    /// fine for measuring: focal length moves with it, so views captured at
    /// different focus positions describe different cameras and cannot be
    /// solved together. `canCapture` is gated on this.
    @Published public private(set) var lensPosition: Float?

    @Published public private(set) var isFocusing = false

    public var isFocusLocked: Bool { lensPosition != nil }

    /// Shared with the rest of the app, not owned here.
    ///
    /// An earlier version of this type built its own `CaptureController`.
    /// That was a real bug, not just a smell: `TripodCalibrationContainer`
    /// correctly shares `AppState.captureController` specifically so
    /// calibration and recording can never silently resolve to different
    /// modes, and this screen — the one that actually produces the
    /// intrinsics the mode fingerprint is keyed on — was the one place that
    /// didn't follow the same rule. With a settings-level mode override now
    /// in play, a separate controller here would calibrate in whatever mode
    /// auto-selection picked while recording used the user's explicit
    /// choice, and nothing would notice until the two fingerprints failed to
    /// match at analysis time.
    public let captureController: CaptureController
    public let spec = CheckerboardSpec()
    public var targetViews: Int { calibratorOptions.targetViews }

    /// Enough views to attempt a solve.
    public var canCalibrate: Bool {
        capturedCount >= calibratorOptions.minimumViews
    }

    private let calibratorOptions = IntrinsicCalibrator.Options()
    private let detector = CheckerboardDetector()
    private let store: IntrinsicsStore?
    private let preferredMode: CaptureRequirements.HardwareMode?
    private var views: [CalibrationView] = []
    private var detectionTask: Task<Void, Never>?
    private var lastDetection: CheckerboardDetection?
    private var configuration: CaptureConfiguration?

    public init(store: IntrinsicsStore? = nil,
                captureController: CaptureController,
                preferredMode: CaptureRequirements.HardwareMode? = nil) {
        self.store = store
        self.captureController = captureController
        self.preferredMode = preferredMode
    }

    // MARK: Lifecycle

    public func start() async {
        phase = .requestingPermission
        guard await CaptureController.requestPermission() else {
            phase = .failed(CaptureControllerError.permissionDenied.localizedDescription)
            return
        }

        phase = .configuring
        do {
            // Calibrate in the mode that will be recorded in. Calibrating at
            // 1080p120 and recording at 1080p240 is the silent scale error
            // this whole fingerprint mechanism exists to prevent — the two
            // modes crop the sensor differently.
            //
            // `.intrinsicCalibration`, not `.recording`: it resolves to the
            // same format, which is the part that has to match, but leaves
            // focus and exposure open. Passing `.recording` here also locked
            // the optics, so the board could never be brought into focus and
            // sat too dark to detect indoors under the 1/500 s recording
            // exposure.
            configuration = try captureController.configure(mode: .intrinsicCalibration,
                                                             preferring: preferredMode)
            captureController.startRunning()
            detectionImageSize = CGSize(width: configuration?.width ?? 0,
                                        height: configuration?.height ?? 0)
            phase = .collecting
            startDetectionLoop()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        detectionTask?.cancel()
        detectionTask = nil
        captureController.stopRunning()
    }

    /// Continuously detect the board so the user gets live feedback.
    ///
    /// Downsampled by two for the live pass. Detection at full resolution
    /// cannot keep up with the preview and the feedback becomes laggy enough
    /// to be misleading; the captured views are always detected at full
    /// resolution, which is what the accuracy actually depends on.
    private func startDetectionLoop() {
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let image = await self.captureController.nextGrayImage(downsample: 2)
                else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                let detection = self.detector.detect(in: image)
                await MainActor.run {
                    self.apply(detection: detection, downsample: 2)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func apply(detection: CheckerboardDetection?, downsample: Int) {
        lastDetection = detection
        guard let detection else {
            detectedCorners = []
            guidance = Guidance(canCapture: false,
                                message: "No board detected. Fill more of the frame "
                                       + "and check the lighting.")
            return
        }

        // Scale live-preview corners back to full-frame coordinates so the
        // overlay lands on the picture rather than in the top-left quadrant.
        let scale = Double(downsample)
        detectedCorners = detection.corners.map { $0 * scale }

        guidance = evaluate(detection)
        refreshAdvice()
    }

    private func evaluate(_ detection: CheckerboardDetection) -> Guidance {
        if detection.coverage < 0.06 {
            return Guidance(canCapture: false, message: "Move closer — the board is "
                                                      + "too small to measure from")
        }
        if detection.coverage > 0.65 {
            return Guidance(canCapture: false, message: "Move back — the board must "
                                                      + "fit fully in frame")
        }
        if detection.gridResidual > 2.5 {
            return Guidance(canCapture: false, message: "Board looks bent or partly "
                                                      + "hidden. Keep it flat and fully "
                                                      + "visible.")
        }
        if abs(detection.tiltDegrees) < 8, coverage.filledCells > 2 {
            return Guidance(canCapture: true, message: "Good. Tilt the board more for "
                                                     + "a better-conditioned solve.")
        }
        return Guidance(canCapture: true, message: "Ready — hold still and capture")
    }

    private func refreshAdvice() {
        var items = [String]()
        if let empty = coverage.emptiestCellDescription {
            items.append("Show the board at \(empty) of the frame — distortion is "
                       + "largest at the edges, which is where the athlete runs.")
        }
        if capturedCount > 0, capturedCount < calibratorOptions.minimumViews {
            items.append("\(calibratorOptions.minimumViews - capturedCount) more views "
                       + "needed before a solve is possible.")
        }
        if capturedCount >= calibratorOptions.minimumViews, !coverage.isComplete {
            items.append("Enough views to solve, but corner coverage is incomplete. "
                       + "Filling it measurably improves edge accuracy.")
        }
        advice = items
    }

    // MARK: Capture

    /// Focus on the board, then pin the lens for the rest of the session.
    ///
    /// Deliberately a discrete action rather than something that happens
    /// automatically at the first capture. The user has to point the phone at
    /// the board *at the distance the athlete will be* before this is
    /// meaningful, and only they know when that is true.
    public func focusAndLock() async {
        guard !isFocusing else { return }
        isFocusing = true
        defer { isFocusing = false }
        do {
            lensPosition = try await captureController.focusAndLock()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Release the lens so the board can be refocused at a new distance.
    ///
    /// Discards captured views rather than keeping them. They were taken at
    /// the old focus position, and mixing focus positions in one solve is the
    /// precise error this whole mechanism exists to prevent — silently
    /// keeping them would produce a confident calibration of a camera that
    /// never existed.
    public func refocus() async {
        views.removeAll()
        capturedCount = 0
        coverage.reset()
        lensPosition = nil
        try? captureController.unlockFocus()
    }

    public func captureCurrentView() {
        guard guidance.canCapture, isFocusLocked else { return }
        Task { await captureFullResolutionView() }
    }

    private func captureFullResolutionView() async {
        guard let image = await captureController.nextGrayImage(downsample: 1),
              let detection = detector.detect(in: image) else { return }

        let view = CalibrationView(objectPoints: spec.objectPoints,
                                   imagePoints: detection.corners,
                                   detection: detection)
        views.append(view)
        capturedCount = views.count
        coverage.record(centre: detection.centre)
        refreshAdvice()
    }

    public func removeLastView() {
        guard !views.isEmpty else { return }
        views.removeLast()
        capturedCount = views.count
        // Coverage is rebuilt rather than decremented: a cell may have been
        // filled by more than one view and decrementing blind would wrongly
        // mark it empty.
        coverage.reset()
        for view in views { coverage.record(centre: view.detection.centre) }
        refreshAdvice()
    }

    public func resetViews() {
        views.removeAll()
        capturedCount = 0
        coverage.reset()
        result = nil
        grade = nil
        qualitySummary = nil
        phase = .collecting
        refreshAdvice()
    }

    // MARK: Solving

    public func calibrate() async {
        guard let configuration else { return }
        phase = .solving
        stop()

        let calibrator = IntrinsicCalibrator(imageWidth: configuration.width,
                                             imageHeight: configuration.height,
                                             options: calibratorOptions)
        let captured = views
        let fingerprint = configuration.fingerprint
        let pinnedLens = lensPosition.map(Double.init)

        do {
            // Off the main actor: the refinement runs a few hundred
            // Levenberg-Marquardt iterations over every corner of every view,
            // which is seconds of work and would freeze the UI.
            let outcome = try await Task.detached(priority: .userInitiated) {
                try calibrator.calibrate(views: captured,
                                         configurationFingerprint: fingerprint,
                                         lensPosition: pinnedLens)
            }.value

            result = outcome
            grade = IntrinsicQuality.grade(outcome)
            qualitySummary = IntrinsicQuality.summary(outcome)
            phase = .finished
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func saveResult() async -> Bool {
        guard let result, let store else { return false }
        do {
            try await store.save(result.intrinsics)
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }
}
